require 'net/http'
require 'json'
require 'uri'

# Slack 채널 이름과 채널 ID를 매핑하는 클래스
# Rails 캐시를 활용하여 Slack API 호출을 최소화합니다.
class SlackChannelMapper
  CACHE_KEY = 'slack_channel_mapping'
  CACHE_EXPIRES_IN = 1.day

  class << self
    # 채널 이름으로 채널 ID 조회
    # @param channel_name [String] 채널 이름 (#없이 또는 #포함 모두 가능)
    # @return [String, nil] 채널 ID 또는 nil
    def get_channel_id(channel_name)
      return nil if channel_name.blank?

      # #으로 시작하면 제거
      clean_name = channel_name.start_with?('#') ? channel_name[1..-1] : channel_name

      channel_map = fetch_channel_mapping
      channel_map[clean_name]&.dig(:id)
    end

    # 채널 ID로 채널 정보 조회
    # @param channel_id [String] 채널 ID
    # @return [Hash, nil] 채널 정보 또는 nil
    def get_channel_info(channel_id)
      return nil if channel_id.blank?

      channel_map = fetch_channel_mapping
      channel_map.values.find { |info| info[:id] == channel_id }
    end

    # 채널 이름으로 채널 정보 조회
    # @param channel_name [String] 채널 이름
    # @return [Hash, nil] 채널 정보 { id:, name:, is_private:, is_member: }
    def get_channel_details(channel_name)
      return nil if channel_name.blank?

      clean_name = channel_name.start_with?('#') ? channel_name[1..-1] : channel_name

      channel_map = fetch_channel_mapping
      channel_map[clean_name]
    end

    # 채널에 메시지 전송
    # @param channel_name [String] 채널 이름 (ID도 가능)
    # @param message [String, Hash] 전송할 메시지
    # @return [Boolean] 전송 성공 여부
    def send_message(channel_name, message)
      return false if channel_name.blank?
      return false unless message

      # 개발 모드 체크
      settings = Setting.plugin_redmine_tx_slack_reminder
      if Rails.env.development? && settings['send_message_on_development_mode'] != '1'
        Rails.logger.info "개발 모드에서 Slack 메시지 전송이 비활성화되어 있습니다."
        return false
      end

      # 채널 ID 확인 (C로 시작하면 ID, 아니면 이름으로 조회)
      channel_id = if channel_name.start_with?('C', 'D')
                     channel_name
                   else
                     get_channel_id(channel_name)
                   end

      return false unless channel_id

      token = slack_token
      return false unless token

      # TxReminderRefactored의 slack_message 메서드 활용
      TxReminderRefactored.slack_message(message, channel_id)
      true
    rescue => e
      Rails.logger.error "Slack 채널 메시지 전송 중 오류 (#{channel_name}): #{e.message}"
      false
    end

    # 캐시 강제 갱신
    def refresh_mapping
      Rails.logger.info "Slack 채널 매핑을 갱신합니다..."
      Rails.cache.delete(CACHE_KEY)
      fetch_channel_mapping(force: true)
    end

    # 모든 채널 매핑 정보 조회 (디버깅용)
    # @return [Hash] 채널명 => { id:, is_private:, is_member: } 형태의 해시
    def all_mappings
      fetch_channel_mapping
    end

    # Public 채널만 조회
    def public_channels
      fetch_channel_mapping.select { |_, info| !info[:is_private] }
    end

    # Private 채널만 조회
    def private_channels
      fetch_channel_mapping.select { |_, info| info[:is_private] }
    end

    # Bot이 참여한 채널만 조회
    def joined_channels
      fetch_channel_mapping.select { |_, info| info[:is_member] }
    end

    # 채널 검색 (부분 일치)
    # @param query [String] 검색어
    # @return [Hash] 일치하는 채널들
    def search_channels(query)
      return {} if query.blank?

      query_lower = query.downcase
      fetch_channel_mapping.select do |name, _|
        name.downcase.include?(query_lower)
      end
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

    # 채널 매핑 정보 조회 (캐시 활용)
    # @param force [Boolean] 강제로 API 호출 여부
    # @return [Hash] 채널명 => { id:, is_private:, is_member: } 형태의 해시
    def fetch_channel_mapping(force: false)
      if force
        mapping = fetch_from_slack_api
        Rails.cache.write(CACHE_KEY, mapping, expires_in: CACHE_EXPIRES_IN)
        return mapping
      end

      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_EXPIRES_IN) do
        fetch_from_slack_api
      end
    end

    # Slack API에서 채널 목록 조회
    # @return [Hash] 채널명 => { id:, is_private:, is_member: } 형태의 해시
    def fetch_from_slack_api
      token = slack_token
      return {} unless token

      channel_map = {}

      # Public 채널과 Private 채널을 모두 조회
      # types: public_channel (public), private_channel (private)
      ['public_channel', 'private_channel'].each do |channel_type|
        channels = fetch_channels_by_type(token, channel_type)
        channel_map.merge!(channels)
      end

      Rails.logger.info "Slack 채널 #{channel_map.size}개를 매핑했습니다."
      channel_map
    rescue => e
      Rails.logger.error "Slack API 호출 중 오류: #{e.message}"
      {}
    end

    # 특정 타입의 채널 조회 (페이지네이션 처리)
    # @param token [String] Slack Bot Token
    # @param channel_type [String] 채널 타입 (public_channel, private_channel)
    # @return [Hash] 채널명 => { id:, is_private:, is_member: } 형태의 해시
    def fetch_channels_by_type(token, channel_type)
      channels = {}
      cursor = nil
      is_private = (channel_type == 'private_channel')

      loop do
        uri = URI('https://slack.com/api/conversations.list')
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json; charset=utf-8'
        request['Authorization'] = "Bearer #{token}"

        body = {
          types: channel_type,
          exclude_archived: true,
          limit: 200
        }
        body[:cursor] = cursor if cursor

        request.body = body.to_json

        response = http.request(request)
        result = JSON.parse(response.body)

        unless result['ok']
          error_msg = result['error']

          # Private 채널 조회 시 권한 부족은 경고만 출력
          if is_private && error_msg == 'missing_scope'
            Rails.logger.warn "Private 채널 조회 권한이 없습니다. (groups:read scope 필요)"
          else
            Rails.logger.error "Slack API 호출 실패: #{error_msg}"
          end

          break
        end

        if result['channels']
          result['channels'].each do |channel|
            # 채널 이름과 정보 저장
            channels[channel['name']] = {
              id: channel['id'],
              is_private: is_private,
              is_member: channel['is_member'] || false,
              num_members: channel['num_members'],
              topic: channel['topic']&.dig('value'),
              purpose: channel['purpose']&.dig('value')
            }
          end
        end

        # 다음 페이지 확인
        cursor = result.dig('response_metadata', 'next_cursor')
        break if cursor.nil? || cursor.empty?
      end

      type_name = is_private ? 'Private' : 'Public'
      member_count = channels.count { |_, info| info[:is_member] }
      Rails.logger.info "#{type_name} 채널 #{channels.size}개 조회 (참여중: #{member_count}개)"

      channels
    end
  end
end
