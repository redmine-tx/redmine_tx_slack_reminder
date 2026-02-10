require 'net/http'
require 'json'
require 'uri'

# Redmine 사용자와 Slack 사용자를 매핑하는 클래스
# Rails 캐시를 활용하여 Slack API 호출을 최소화합니다.
class SlackUserMapper
  CACHE_KEY = 'slack_user_mapping'
  CACHE_EXPIRES_IN = 1.day

  class << self
    # Redmine 로그인명으로 Slack 사용자 ID 조회
    # @param login [String] Redmine 로그인명
    # @return [String, nil] Slack 사용자 ID 또는 nil
    def get_slack_user_id(login)
      return nil if login.blank?

      user_map = fetch_user_mapping
      user_map[login]&.dig(:id)
    end

    # Redmine User 객체로 Slack 사용자 ID 조회
    # @param user [User] Redmine User 객체
    # @return [String, nil] Slack 사용자 ID 또는 nil
    def get_slack_user_id_by_user(user)
      return nil unless user.is_a?(User)
      get_slack_user_id(user.login)
    end

    # DM 채널 열기
    # @param login [String] Redmine 로그인명
    # @return [String, nil] Slack DM 채널 ID 또는 nil
    def open_dm_channel(login)
      user_id = get_slack_user_id(login)
      return nil unless user_id

      token = slack_token
      return nil unless token

      uri = URI('https://slack.com/api/conversations.open')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{token}"
      request.body = { users: user_id }.to_json

      response = http.request(request)
      result = JSON.parse(response.body)

      if result['ok']
        channel_id = result['channel']['id']
        # 채널 ID를 캐시에 저장
        update_user_channel(login, channel_id)
        channel_id
      else
        Rails.logger.error "Slack DM 채널 열기 실패: #{result['error']}"
        nil
      end
    rescue => e
      Rails.logger.error "Slack DM 채널 열기 중 오류: #{e.message}"
      nil
    end

    # Redmine 사용자에게 DM 전송
    # @param login [String] Redmine 로그인명
    # @param message [String, Hash] 전송할 메시지 (문자열 또는 Slack 블록)
    # @return [Boolean] 전송 성공 여부
    def send_dm(login, message)
      return false if login.blank?
      return false unless message

      # 개발 모드에서 메시지 전송 설정 확인
      settings = Setting.plugin_redmine_tx_slack_reminder
      if Rails.env.development? && settings['send_message_on_development_mode'] != '1'
        Rails.logger.info "개발 모드에서 Slack 메시지 전송이 비활성화되어 있습니다."
        return false
      end

      channel_id = get_dm_channel(login)
      return false unless channel_id

      token = slack_token
      return false unless token

      uri = URI('https://slack.com/api/chat.postMessage')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{token}"

      body = if message.is_a?(String)
               {
                 channel: channel_id,
                 text: message
               }
             else
               {
                 channel: channel_id,
                 text: '알림',  # fallback text
                 blocks: [message]
               }
             end

      request.body = body.to_json
      response = SlackRateLimiter.send_with_throttle(http, request, channel_id)
      result = JSON.parse(response.body)

      if result['ok']
        true
      else
        # channel_not_found 오류인 경우 채널을 다시 열고 재시도
        if result['error'] == 'channel_not_found'
          Rails.logger.info "DM 채널을 찾을 수 없어 다시 엽니다: #{login}"
          clear_user_channel(login)
          new_channel_id = open_dm_channel(login)
          if new_channel_id
            body[:channel] = new_channel_id
            request.body = body.to_json
            retry_response = SlackRateLimiter.send_with_throttle(http, request, new_channel_id)
            retry_result = JSON.parse(retry_response.body)
            return retry_result['ok']
          end
        end

        Rails.logger.error "Slack DM 전송 실패 (#{login}): #{result['error']}"
        false
      end
    rescue => e
      Rails.logger.error "Slack DM 전송 중 오류 (#{login}): #{e.message}"
      false
    end

    # Redmine User 객체에게 DM 전송
    # @param user [User] Redmine User 객체
    # @param message [String, Hash] 전송할 메시지
    # @return [Boolean] 전송 성공 여부
    def send_dm_to_user(user, message)
      return false unless user.is_a?(User)
      send_dm(user.login, message)
    end

    # 캐시 강제 갱신
    # Slack API를 호출하여 최신 사용자 목록을 가져옵니다.
    def refresh_mapping
      Rails.logger.info "Slack 사용자 매핑을 갱신합니다..."
      Rails.cache.delete(CACHE_KEY)
      fetch_user_mapping(force: true)
    end

    # 모든 매핑 정보 조회 (디버깅용)
    # @return [Hash] 로그인명 => { id: slack_id, channel: channel_id } 형태의 해시
    def all_mappings
      fetch_user_mapping
    end

    private

    # Slack 토큰 조회
    def slack_token
      token = Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_token']
      if token.blank?
        Rails.logger.error "Slack 토큰이 설정되지 않았습니다."
        return nil
      end
      token
    end

    # DM 채널 ID 조회 (캐시에서)
    def get_dm_channel(login)
      user_map = fetch_user_mapping
      channel_id = user_map[login]&.dig(:channel)

      # 채널이 없으면 새로 열기
      if channel_id.nil?
        channel_id = open_dm_channel(login)
      end

      channel_id
    end

    # 사용자의 채널 ID를 캐시에서 제거
    def clear_user_channel(login)
      user_map = fetch_user_mapping
      if user_map[login]
        user_map[login].delete(:channel)
        Rails.cache.write(CACHE_KEY, user_map, expires_in: CACHE_EXPIRES_IN)
      end
    end

    # 사용자의 채널 ID 업데이트
    def update_user_channel(login, channel_id)
      user_map = fetch_user_mapping
      if user_map[login]
        user_map[login][:channel] = channel_id
        Rails.cache.write(CACHE_KEY, user_map, expires_in: CACHE_EXPIRES_IN)
      end
    end

    # 사용자 매핑 정보 조회 (캐시 활용)
    # @param force [Boolean] 강제로 API 호출 여부
    # @return [Hash] 로그인명 => { id: slack_id, channel: channel_id } 형태의 해시
    def fetch_user_mapping(force: false)
      if force
        mapping = fetch_from_slack_api
        if mapping.present?
          Rails.cache.write(CACHE_KEY, mapping, expires_in: CACHE_EXPIRES_IN)
        end
        return mapping
      end

      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached.present?

      mapping = fetch_from_slack_api
      if mapping.present?
        Rails.cache.write(CACHE_KEY, mapping, expires_in: CACHE_EXPIRES_IN)
      end
      mapping
    end

    # Slack API에서 사용자 목록 조회
    # @return [Hash] 로그인명 => { id: slack_id } 형태의 해시
    def fetch_from_slack_api
      token = slack_token
      return {} unless token

      uri = URI('https://slack.com/api/users.list')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{token}"
      request.body = { token: token }.to_json

      response = http.request(request)
      result = JSON.parse(response.body)

      if result['ok'] && result['members']
        user_map = {}
        result['members'].each do |user|
          next if user['deleted']

          email = user.dig('profile', 'email')
          next if email.nil?

          # 이메일에서 @ 앞부분을 추출하여 로그인명으로 사용
          login = email.split('@').first
          user_map[login] = { id: user['id'] }
        end

        Rails.logger.info "Slack 사용자 #{user_map.size}명을 매핑했습니다."
        user_map
      else
        Rails.logger.error "Slack API 호출 실패: #{result['error']}"
        {}
      end
    rescue => e
      Rails.logger.error "Slack API 호출 중 오류: #{e.message}"
      {}
    end
  end
end
