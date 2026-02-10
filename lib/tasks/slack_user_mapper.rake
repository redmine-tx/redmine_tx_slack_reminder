namespace :slack_user_mapper do
  desc 'Slack 사용자 매핑 정보 조회'
  task :list => :environment do
    mappings = SlackUserMapper.all_mappings

    if mappings.empty?
      puts "매핑된 사용자가 없습니다."
      puts "Slack Bot Token이 올바르게 설정되었는지 확인하세요."
    else
      puts "총 #{mappings.size}명의 사용자가 매핑되었습니다."
      puts ""
      puts "%-20s %-15s %-15s" % ["Redmine 로그인", "Slack User ID", "DM 채널 ID"]
      puts "-" * 52

      mappings.sort.each do |login, info|
        slack_id = info[:id] || 'N/A'
        channel_id = info[:channel] || '-'
        puts "%-20s %-15s %-15s" % [login, slack_id, channel_id]
      end
    end
  end

  desc 'Slack 사용자 매핑 강제 갱신'
  task :refresh => :environment do
    puts "Slack 사용자 매핑을 갱신합니다..."
    SlackUserMapper.refresh_mapping

    mappings = SlackUserMapper.all_mappings
    puts "완료: #{mappings.size}명의 사용자가 매핑되었습니다."
  end

  desc '특정 사용자에게 테스트 DM 전송'
  task :test_dm, [:login] => :environment do |t, args|
    login = args[:login]

    if login.blank?
      puts "사용법: rake slack_user_mapper:test_dm[로그인명]"
      puts "예시: rake slack_user_mapper:test_dm[john.doe]"
      exit 1
    end

    user = User.find_by(login: login)

    if user.nil?
      puts "오류: '#{login}' 사용자를 찾을 수 없습니다."
      exit 1
    end

    slack_id = SlackUserMapper.get_slack_user_id(login)

    if slack_id.nil?
      puts "오류: '#{login}' 사용자가 Slack에 매핑되지 않았습니다."
      puts "Slack에서 이메일이 '#{login}@...'로 시작하는 사용자가 있는지 확인하세요."
      exit 1
    end

    puts "사용자 정보:"
    puts "  Redmine: #{user.name} (#{login})"
    puts "  Slack ID: #{slack_id}"
    puts ""
    puts "테스트 메시지를 전송합니다..."

    message = "[테스트] Redmine Slack 알림 테스트입니다. 이 메시지를 받으셨다면 설정이 올바르게 완료되었습니다."

    result = SlackUserMapper.send_dm(login, message)

    if result
      puts "성공: 메시지가 전송되었습니다."
    else
      puts "실패: 메시지 전송에 실패했습니다. 로그를 확인하세요."
      exit 1
    end
  end

  desc '여러 사용자에게 테스트 DM 전송'
  task :test_dm_bulk, [:logins] => :environment do |t, args|
    logins_str = args[:logins]

    if logins_str.blank?
      puts "사용법: rake slack_user_mapper:test_dm_bulk[로그인1,로그인2,로그인3]"
      puts "예시: rake slack_user_mapper:test_dm_bulk[john.doe,jane.smith]"
      exit 1
    end

    logins = logins_str.split(',').map(&:strip)

    puts "#{logins.size}명의 사용자에게 테스트 메시지를 전송합니다..."
    puts ""

    success_count = 0
    failure_count = 0

    logins.each do |login|
      user = User.find_by(login: login)

      if user.nil?
        puts "[#{login}] 실패: 사용자를 찾을 수 없음"
        failure_count += 1
        next
      end

      message = "[테스트] #{user.name}님, Redmine Slack 알림 테스트입니다."
      result = SlackUserMapper.send_dm(login, message)

      if result
        puts "[#{login}] 성공"
        success_count += 1
      else
        puts "[#{login}] 실패: 메시지 전송 실패"
        failure_count += 1
      end

      # API rate limit을 고려하여 짧은 대기
      sleep 0.5
    end

    puts ""
    puts "전송 완료: 성공 #{success_count}건, 실패 #{failure_count}건"
  end

  desc 'Redmine 사용자와 Slack 매핑 상태 확인'
  task :check_mapping => :environment do
    puts "Redmine 활성 사용자와 Slack 매핑 상태를 확인합니다..."
    puts ""

    mappings = SlackUserMapper.all_mappings
    active_users = User.active.sorted

    mapped_users = []
    unmapped_users = []

    active_users.each do |user|
      if mappings[user.login]
        mapped_users << user
      else
        unmapped_users << user
      end
    end

    puts "=== 매핑된 사용자 (#{mapped_users.size}명) ==="
    mapped_users.each do |user|
      slack_info = mappings[user.login]
      puts "  ✓ #{user.name} (#{user.login}) → #{slack_info[:id]}"
    end

    puts ""
    puts "=== 매핑되지 않은 사용자 (#{unmapped_users.size}명) ==="
    unmapped_users.each do |user|
      puts "  ✗ #{user.name} (#{user.login})"
      puts "    → Slack에서 이메일이 '#{user.login}@...'인 사용자가 필요합니다."
    end

    puts ""
    puts "요약:"
    puts "  전체 활성 사용자: #{active_users.size}명"
    puts "  매핑된 사용자: #{mapped_users.size}명 (#{(mapped_users.size.to_f / active_users.size * 100).round(1)}%)"
    puts "  매핑 안 된 사용자: #{unmapped_users.size}명"
  end

  desc '캐시 정보 조회'
  task :cache_info => :environment do
    cache_key = 'slack_user_mapping'
    cached_data = Rails.cache.read(cache_key)

    if cached_data.nil?
      puts "캐시가 비어있습니다."
      puts "처음 조회 시 자동으로 Slack API를 호출하여 캐시를 생성합니다."
    else
      puts "캐시 정보:"
      puts "  키: #{cache_key}"
      puts "  항목 수: #{cached_data.size}개"
      puts "  만료 시간: 1일 (86400초)"
      puts ""
      puts "캐시를 강제로 갱신하려면 다음 명령을 실행하세요:"
      puts "  rake slack_user_mapper:refresh"
    end
  end

  desc '캐시 삭제'
  task :clear_cache => :environment do
    cache_key = 'slack_user_mapping'
    Rails.cache.delete(cache_key)
    puts "캐시가 삭제되었습니다."
    puts "다음 조회 시 Slack API를 호출하여 새로 생성됩니다."
  end
end
