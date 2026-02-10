namespace :slack_channel_mapper do
  desc 'Slack 채널 매핑 정보 조회'
  task :list => :environment do
    mappings = SlackChannelMapper.all_mappings

    if mappings.empty?
      puts "매핑된 채널이 없습니다."
      puts "Slack Bot Token이 올바르게 설정되었는지 확인하세요."
    else
      puts "총 #{mappings.size}개의 채널이 매핑되었습니다."
      puts ""

      # Public 채널
      public_channels = mappings.select { |_, info| !info[:is_private] }
      if public_channels.any?
        puts "=== Public 채널 (#{public_channels.size}개) ==="
        puts "%-30s %-15s %-10s %-10s" % ["채널명", "채널 ID", "참여여부", "멤버수"]
        puts "-" * 70

        public_channels.sort.each do |name, info|
          member_status = info[:is_member] ? '참여중' : '-'
          member_count = info[:num_members] || '-'
          puts "%-30s %-15s %-10s %-10s" % ["##{name}", info[:id], member_status, member_count]
        end
        puts ""
      end

      # Private 채널
      private_channels = mappings.select { |_, info| info[:is_private] }
      if private_channels.any?
        puts "=== Private 채널 (#{private_channels.size}개) ==="
        puts "%-30s %-15s %-10s %-10s" % ["채널명", "채널 ID", "참여여부", "멤버수"]
        puts "-" * 70

        private_channels.sort.each do |name, info|
          member_status = info[:is_member] ? '참여중' : '-'
          member_count = info[:num_members] || '-'
          puts "%-30s %-15s %-10s %-10s" % ["##{name}", info[:id], member_status, member_count]
        end
        puts ""
      end

      # 통계
      joined_count = mappings.count { |_, info| info[:is_member] }
      puts "요약:"
      puts "  전체 채널: #{mappings.size}개"
      puts "  Public: #{public_channels.size}개"
      puts "  Private: #{private_channels.size}개"
      puts "  Bot 참여중: #{joined_count}개"
    end
  end

  desc 'Bot이 참여한 채널만 조회'
  task :joined => :environment do
    joined = SlackChannelMapper.joined_channels

    if joined.empty?
      puts "Bot이 참여한 채널이 없습니다."
    else
      puts "Bot이 참여한 채널 (#{joined.size}개)"
      puts ""
      puts "%-30s %-15s %-10s" % ["채널명", "채널 ID", "타입"]
      puts "-" * 58

      joined.sort.each do |name, info|
        channel_type = info[:is_private] ? 'Private' : 'Public'
        puts "%-30s %-15s %-10s" % ["##{name}", info[:id], channel_type]
      end
    end
  end

  desc 'Public 채널만 조회'
  task :public => :environment do
    public_channels = SlackChannelMapper.public_channels

    if public_channels.empty?
      puts "Public 채널이 없습니다."
    else
      puts "Public 채널 (#{public_channels.size}개)"
      puts ""
      puts "%-30s %-15s %-10s %-10s" % ["채널명", "채널 ID", "참여여부", "멤버수"]
      puts "-" * 70

      public_channels.sort.each do |name, info|
        member_status = info[:is_member] ? '참여중' : '-'
        member_count = info[:num_members] || '-'
        puts "%-30s %-15s %-10s %-10s" % ["##{name}", info[:id], member_status, member_count]
      end
    end
  end

  desc 'Private 채널만 조회'
  task :private => :environment do
    private_channels = SlackChannelMapper.private_channels

    if private_channels.empty?
      puts "Private 채널이 없습니다."
      puts ""
      puts "주의: Bot이 초대된 Private 채널만 조회할 수 있습니다."
      puts "      Bot Token에 groups:read 권한이 필요합니다."
    else
      puts "Private 채널 (#{private_channels.size}개)"
      puts ""
      puts "%-30s %-15s %-10s %-10s" % ["채널명", "채널 ID", "참여여부", "멤버수"]
      puts "-" * 70

      private_channels.sort.each do |name, info|
        member_status = info[:is_member] ? '참여중' : '-'
        member_count = info[:num_members] || '-'
        puts "%-30s %-15s %-10s %-10s" % ["##{name}", info[:id], member_status, member_count]
      end
    end
  end

  desc '채널 검색'
  task :search, [:query] => :environment do |t, args|
    query = args[:query]

    if query.blank?
      puts "사용법: rake slack_channel_mapper:search[검색어]"
      puts "예시: rake slack_channel_mapper:search[dev]"
      exit 1
    end

    results = SlackChannelMapper.search_channels(query)

    if results.empty?
      puts "'#{query}'에 일치하는 채널이 없습니다."
    else
      puts "'#{query}' 검색 결과 (#{results.size}개)"
      puts ""
      puts "%-30s %-15s %-10s %-10s" % ["채널명", "채널 ID", "타입", "참여여부"]
      puts "-" * 70

      results.sort.each do |name, info|
        channel_type = info[:is_private] ? 'Private' : 'Public'
        member_status = info[:is_member] ? '참여중' : '-'
        puts "%-30s %-15s %-10s %-10s" % ["##{name}", info[:id], channel_type, member_status]
      end
    end
  end

  desc '채널 상세 정보 조회'
  task :info, [:channel_name] => :environment do |t, args|
    channel_name = args[:channel_name]

    if channel_name.blank?
      puts "사용법: rake slack_channel_mapper:info[채널명]"
      puts "예시: rake slack_channel_mapper:info[general]"
      exit 1
    end

    info = SlackChannelMapper.get_channel_details(channel_name)

    if info.nil?
      puts "채널 '#{channel_name}'을 찾을 수 없습니다."
      exit 1
    end

    puts "채널 정보:"
    puts "  이름: ##{channel_name}"
    puts "  ID: #{info[:id]}"
    puts "  타입: #{info[:is_private] ? 'Private' : 'Public'}"
    puts "  Bot 참여: #{info[:is_member] ? '예' : '아니오'}"
    puts "  멤버수: #{info[:num_members] || 'N/A'}"

    if info[:topic] && !info[:topic].empty?
      puts "  주제: #{info[:topic]}"
    end

    if info[:purpose] && !info[:purpose].empty?
      puts "  목적: #{info[:purpose]}"
    end
  end

  desc 'Slack 채널 매핑 강제 갱신'
  task :refresh => :environment do
    puts "Slack 채널 매핑을 갱신합니다..."
    SlackChannelMapper.refresh_mapping

    mappings = SlackChannelMapper.all_mappings
    public_count = mappings.count { |_, info| !info[:is_private] }
    private_count = mappings.count { |_, info| info[:is_private] }

    puts "완료: 총 #{mappings.size}개 채널 매핑"
    puts "  Public: #{public_count}개"
    puts "  Private: #{private_count}개"
  end

  desc '채널에 테스트 메시지 전송'
  task :test_message, [:channel_name] => :environment do |t, args|
    channel_name = args[:channel_name]

    if channel_name.blank?
      puts "사용법: rake slack_channel_mapper:test_message[채널명]"
      puts "예시: rake slack_channel_mapper:test_message[general]"
      puts "      rake slack_channel_mapper:test_message[C1234567890]"
      exit 1
    end

    # 채널 정보 확인
    if channel_name.start_with?('C', 'D')
      channel_id = channel_name
      info = SlackChannelMapper.get_channel_info(channel_id)
      display_name = info ? "##{info[:name]}" : channel_id
    else
      info = SlackChannelMapper.get_channel_details(channel_name)
      if info.nil?
        puts "오류: '#{channel_name}' 채널을 찾을 수 없습니다."
        exit 1
      end
      display_name = "##{channel_name}"
      channel_id = info[:id]
    end

    # Bot 참여 확인
    if info && !info[:is_member]
      puts "경고: Bot이 이 채널에 참여하지 않았습니다."
      puts "      메시지 전송이 실패할 수 있습니다."
      puts ""
    end

    puts "채널 정보:"
    puts "  이름: #{display_name}"
    puts "  ID: #{channel_id}"
    puts "  타입: #{info[:is_private] ? 'Private' : 'Public'}" if info
    puts ""
    puts "테스트 메시지를 전송합니다..."

    message = "[테스트] Redmine Slack 알림 테스트입니다. 이 메시지를 보셨다면 설정이 올바르게 완료되었습니다."

    result = SlackChannelMapper.send_message(channel_name, message)

    if result
      puts "성공: 메시지가 전송되었습니다."
    else
      puts "실패: 메시지 전송에 실패했습니다. 로그를 확인하세요."
      exit 1
    end
  end

  desc '캐시 정보 조회'
  task :cache_info => :environment do
    cache_key = 'slack_channel_mapping'
    cached_data = Rails.cache.read(cache_key)

    if cached_data.nil?
      puts "캐시가 비어있습니다."
      puts "처음 조회 시 자동으로 Slack API를 호출하여 캐시를 생성합니다."
    else
      public_count = cached_data.count { |_, info| !info[:is_private] }
      private_count = cached_data.count { |_, info| info[:is_private] }
      joined_count = cached_data.count { |_, info| info[:is_member] }

      puts "캐시 정보:"
      puts "  키: #{cache_key}"
      puts "  채널 수: #{cached_data.size}개"
      puts "    - Public: #{public_count}개"
      puts "    - Private: #{private_count}개"
      puts "    - Bot 참여중: #{joined_count}개"
      puts "  만료 시간: 1일 (86400초)"
      puts ""
      puts "캐시를 강제로 갱신하려면 다음 명령을 실행하세요:"
      puts "  rake slack_channel_mapper:refresh"
    end
  end

  desc '캐시 삭제'
  task :clear_cache => :environment do
    cache_key = 'slack_channel_mapping'
    Rails.cache.delete(cache_key)
    puts "캐시가 삭제되었습니다."
    puts "다음 조회 시 Slack API를 호출하여 새로 생성됩니다."
  end

  desc 'TxReminderRefactored 설정을 채널 이름 기반으로 변환'
  task :convert_config => :environment do
    puts "현재 TEAM_CONFIGS의 채널 ID를 채널 이름으로 변환합니다..."
    puts ""

    mappings = SlackChannelMapper.all_mappings
    reverse_map = {}
    mappings.each { |name, info| reverse_map[info[:id]] = name }

    TxReminderRefactored::TEAM_CONFIGS.each do |team_key, config|
      channel_id = config['channel']
      channel_name = reverse_map[channel_id]

      if channel_name
        puts "#{team_key}:"
        puts "  현재: '#{channel_id}'"
        puts "  변환: '##{channel_name}'"
        puts "  'channel' => SlackChannelMapper.get_channel_id('#{channel_name}')"
      else
        puts "#{team_key}: 매핑 정보 없음 (#{channel_id})"
      end
      puts ""
    end

    puts "참고: 실제 변환은 코드를 직접 수정해야 합니다."
  end
end
