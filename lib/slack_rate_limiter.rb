# frozen_string_literal: true

module SlackRateLimiter
  @channel_last_sent = {} # { channel_id => timestamp }
  @mutex = Mutex.new
  @worker_thread = nil

  MIN_INTERVAL = 1.1 # 채널당 최소 간격 (Slack: 1msg/sec/channel)
  MAX_RETRIES = 3

  class << self
    # 블록을 백그라운드 스레드에서 실행 (Puma 스레드 즉시 반환)
    # 이미 실행 중인 스레드가 있으면 중복 실행 방지
    def run_in_background(&block)
      if @worker_thread&.alive?
        Rails.logger.warn "SlackRateLimiter: 이전 작업이 아직 실행 중. 건너뜁니다."
        return
      end

      @worker_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          block.call
        end
      rescue => e
        Rails.logger.error "SlackRateLimiter background error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end
    end

    # 채널별 쓰로틀링 + 429 재시도가 적용된 HTTP 전송
    def send_with_throttle(http, request, channel_id)
      throttle(channel_id)

      retries = 0
      loop do
        response = http.request(request)

        if response.code == '429'
          break response if retries >= MAX_RETRIES
          retry_after = (response['Retry-After'] || 5).to_f
          Rails.logger.warn "Slack 429: #{channel_id}, #{retry_after}s 대기 (#{retries + 1}/#{MAX_RETRIES})"
          sleep(retry_after)
          retries += 1
        elsif response.code != '200'
          break response if retries >= MAX_RETRIES
          sleep(2**retries)
          retries += 1
        else
          record(channel_id)
          break response
        end
      end
    end

    private

    def throttle(channel_id)
      @mutex.synchronize do
        last = @channel_last_sent[channel_id]
        if last
          wait = MIN_INTERVAL - (Time.now.to_f - last)
          sleep(wait) if wait > 0
        end
      end
    end

    def record(channel_id)
      @mutex.synchronize do
        @channel_last_sent[channel_id] = Time.now.to_f
      end
    end
  end
end
