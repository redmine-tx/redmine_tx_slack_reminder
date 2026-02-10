namespace :remind_everybody do
  # 공통: 특정 사용자의 일감을 4개 카테고리로 분류하여 반환
  def fetch_user_issues(user)
    today = Date.current
    dm_exclude_tracker_ids = (Tracker.sidejob_trackers_ids + Tracker.exception_trackers_ids).uniq
    dm_exclude_status_ids = (IssueStatus.completed_ids + IssueStatus.implemented_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids).uniq

    today_issues = Issue.joins(:assigned_to, :status)
      .where('issues.created_on >= ?', TxReminderRefactored::ISSUE_CREATED_AFTER)
      .where(Issue.arel_table[:start_date].eq(today).or(Issue.arel_table[:due_date].eq(today)))
      .where.not(status_id: dm_exclude_status_ids)
      .where(assigned_to_id: user.id)
      .where.not(tracker_id: dm_exclude_tracker_ids)

    overdue_new_issues = Issue.joins(:assigned_to, :status)
      .where('issues.created_on >= ?', TxReminderRefactored::ISSUE_CREATED_AFTER)
      .where('start_date < ?', today)
      .where.not(status_id: dm_exclude_status_ids)
      .where(status_id: IssueStatus.new_ids)
      .where(assigned_to_id: user.id)
      .where.not(tracker_id: dm_exclude_tracker_ids)

    overdue_issues = Issue.joins(:assigned_to, :status)
      .where('issues.created_on >= ?', TxReminderRefactored::ISSUE_CREATED_AFTER)
      .where('due_date < ?', today)
      .where.not(status_id: dm_exclude_status_ids)
      .where(status_id: IssueStatus.in_progress_ids + IssueStatus.new_ids)
      .where(assigned_to_id: user.id)
      .where.not(tracker_id: dm_exclude_tracker_ids)

    all_issues = (today_issues.to_a + overdue_new_issues.to_a + overdue_issues.to_a).uniq(&:id)

    # 현재 진행 구간에 있는 일감 존재 여부 (start_date <= today <= due_date)
    has_ongoing = Issue
      .where('issues.created_on >= ?', TxReminderRefactored::ISSUE_CREATED_AFTER)
      .where('start_date <= ? AND due_date >= ?', today, today)
      .where.not(status_id: dm_exclude_status_ids)
      .where(assigned_to_id: user.id)
      .where.not(tracker_id: dm_exclude_tracker_ids)
      .exists?

    start_list    = all_issues.select { |i| i.start_date == today }
    due_list      = all_issues.select { |i| i.due_date == today }
    new_overdue   = all_issues.select { |i| i.start_date && i.start_date < today && IssueStatus.is_new?(i.status_id) }
    over_list     = all_issues.select { |i| i.due_date && i.due_date < today && !IssueStatus.is_new?(i.status_id) }

    { all: all_issues, start: start_list, due: due_list, new_overdue: new_overdue, overdue: over_list, has_ongoing: has_ongoing }
  end

  desc '개인별 DM 알림 테스트: A의 일감 메시지를 B에게 전송. 사용법: rake remind_everybody:test[A_login,B_login]'
  task :test, [:source_login, :target_login] => :environment do |t, args|
    source_login = args[:source_login]
    target_login = args[:target_login]

    if source_login.blank? || target_login.blank?
      puts "사용법: rake remind_everybody:test[소스_로그인,대상_로그인]"
      puts "  소스_로그인: 일감을 조회할 사용자 (A)"
      puts "  대상_로그인: 메시지를 받을 사용자 (B)"
      puts ""
      puts "예시: rake remind_everybody:test[hong.gildong,kim.cheolsu]"
      puts "  → hong.gildong의 일감 메시지를 kim.cheolsu에게 DM으로 전송"
      exit 1
    end

    source_user = User.find_by(login: source_login)
    target_user = User.find_by(login: target_login)

    if source_user.nil?
      puts "오류: 소스 사용자 '#{source_login}'을 찾을 수 없습니다."
      exit 1
    end

    if target_user.nil?
      puts "오류: 대상 사용자 '#{target_login}'을 찾을 수 없습니다."
      exit 1
    end

    target_slack_id = SlackUserMapper.get_slack_user_id(target_login)
    if target_slack_id.nil?
      puts "오류: 대상 사용자 '#{target_login}'이 Slack에 매핑되지 않았습니다."
      exit 1
    end

    puts "소스 사용자: #{source_user.name} (#{source_login})"
    puts "대상 사용자: #{target_user.name} (#{target_login}) → Slack ID: #{target_slack_id}"
    puts ""

    result = fetch_user_issues(source_user)

    puts "조회 결과:"
    puts "  오늘 시작: #{result[:start].size}건"
    puts "  오늘 마감: #{result[:due].size}건"
    puts "  시작일 경과 미착수: #{result[:new_overdue].size}건"
    puts "  완료기한 초과: #{result[:overdue].size}건"
    puts ""

    no_today = result[:start].empty? && result[:due].empty? && !result[:has_ongoing]
    puts ":warning: 오늘 배정된 일감이 없습니다. 일정을 확인해 주세요." if no_today

    block = TxReminderRefactored.build_personal_dm_block(
      result[:start], result[:due], result[:new_overdue], result[:overdue], no_today: no_today
    )

    puts "메시지를 #{target_user.name}에게 전송합니다..."
    sent = SlackUserMapper.send_dm_to_user(target_user, block)

    if sent
      puts "성공: 메시지가 전송되었습니다."
    else
      puts "실패: 메시지 전송에 실패했습니다. 로그를 확인하세요."
      exit 1
    end
  end

  desc '개인별 DM 알림 미리보기 (전송 없이 콘솔 출력). 사용법: rake remind_everybody:preview[login]'
  task :preview, [:login] => :environment do |t, args|
    login = args[:login]

    if login.blank?
      puts "사용법: rake remind_everybody:preview[로그인]"
      puts "예시: rake remind_everybody:preview[hong.gildong]"
      exit 1
    end

    user = User.find_by(login: login)
    if user.nil?
      puts "오류: 사용자 '#{login}'을 찾을 수 없습니다."
      exit 1
    end

    puts "사용자: #{user.name} (#{login})"
    puts ""

    result = fetch_user_issues(user)

    no_today = result[:start].empty? && result[:due].empty?

    puts "=== 미리보기 ==="
    puts ""

    if no_today
      puts ":white_check_mark: 오늘 해야할 일감이 없습니다."
      puts ""
    end

    if result[:start].any?
      puts ":date: 오늘 시작 일감 #{result[:start].size}건"
      result[:start].each do |i|
        puts "  * ##{i.id} #{i.subject} (#{i.status.name})"
      end
      puts ""
    end

    if result[:due].any?
      puts ":date: 오늘 마감 일감 #{result[:due].size}건"
      result[:due].each do |i|
        puts "  * ##{i.id} #{i.subject} (#{i.status.name})"
      end
      puts ""
    end

    if result[:new_overdue].any?
      puts ":date: 시작일 경과 미착수 일감 #{result[:new_overdue].size}건"
      result[:new_overdue].each do |i|
        days = (Date.current - i.start_date).to_i
        puts "  * ##{i.id} #{i.subject} (#{i.status.name}) -- 시작일 #{days}일 경과"
      end
      puts ""
    end

    if result[:overdue].any?
      puts ":date: 완료기한 초과 일감 #{result[:overdue].size}건"
      result[:overdue].each do |i|
        days = (Date.current - i.due_date).to_i
        puts "  * ##{i.id} #{i.subject} (#{i.status.name}) -- #{days}일 초과"
      end
      puts ""
    end

    puts "=== JSON 블록 ==="
    block = TxReminderRefactored.build_personal_dm_block(
      result[:start], result[:due], result[:new_overdue], result[:overdue], no_today: no_today
    )
    puts JSON.pretty_generate(block)
  end

  desc '전체 대상 사용자의 일간 DM 알림 미리보기 (전송 없이 콘솔 출력). 사용법: rake remind_everybody:preview_all'
  task preview_all: :environment do
    today = Date.current

    group_ids = Setting.plugin_redmine_tx_slack_reminder['dm_target_group_ids'] || []
    group_ids = group_ids.map(&:to_i).reject(&:zero?)

    if group_ids.empty?
      puts "오류: dm_target_group_ids 설정이 비어있습니다."
      exit 1
    end

    target_users = User.active
      .joins('INNER JOIN groups_users ON groups_users.user_id = users.id')
      .where('groups_users.group_id IN (?)', group_ids)
      .distinct.order(:lastname, :firstname).to_a

    puts "=== 일간 DM 알림 미리보기 (#{today}) ==="
    puts "대상 그룹 ID: #{group_ids.join(', ')}"
    puts "대상 사용자: #{target_users.size}명"
    puts ""

    vacation_available = TxBaseHelper::UserVacationApi.available? rescue false
    sent_count = 0
    skip_count = 0

    target_users.each do |user|
      if vacation_available && TxBaseHelper::UserVacationApi.on_vacation?(user, today)
        skip_count += 1
        next
      end

      result = fetch_user_issues(user)

      no_today = result[:start].empty? && result[:due].empty? && !result[:has_ongoing]
      next if !no_today && result[:all].empty?

      sent_count += 1
      puts "--- #{user.name} (#{user.login}) ---"

      if no_today
        puts "  :warning: 오늘 배정된 일감이 없습니다. 일정을 확인해 주세요."
      end

      if result[:start].any?
        puts "  :date: 오늘 시작 일감 #{result[:start].size}건"
        result[:start].each do |i|
          puts "    * ##{i.id} #{i.subject} (#{i.status.name})"
        end
      end

      if result[:due].any?
        puts "  :date: 오늘 마감 일감 #{result[:due].size}건"
        result[:due].each do |i|
          puts "    * ##{i.id} #{i.subject} (#{i.status.name})"
        end
      end

      if result[:new_overdue].any?
        puts "  :date: 시작일 경과 미착수 일감 #{result[:new_overdue].size}건"
        result[:new_overdue].each do |i|
          days = (today - i.start_date).to_i
          puts "    * ##{i.id} #{i.subject} (#{i.status.name}) -- 시작일 #{days}일 경과"
        end
      end

      if result[:overdue].any?
        puts "  :date: 완료기한 초과 일감 #{result[:overdue].size}건"
        result[:overdue].each do |i|
          days = (today - i.due_date).to_i
          puts "    * ##{i.id} #{i.subject} (#{i.status.name}) -- #{days}일 초과"
        end
      end

      puts ""
    end

    puts "=== 요약 ==="
    puts "알림 대상: #{sent_count}명"
    puts "휴가 제외: #{skip_count}명" if skip_count > 0
    puts "알림 없음: #{target_users.size - sent_count - skip_count}명"
  end
end
