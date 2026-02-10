#!/usr/bin/env ruby
# frozen_string_literal: true

# SlackUserMapper와 SlackChannelMapper 통합 활용 예시

require File.expand_path('../../../config/environment', __dir__)

# ============================================
# 예시 1: 채널과 DM 동시 활용
# ============================================
def example_notify_channel_and_assignee
  issue = Issue.find(1234)

  # 1. 프로젝트 채널에 공지
  project_channel = "project-#{issue.project.identifier}"
  if SlackChannelMapper.get_channel_id(project_channel)
    message = "새 일감 ##{issue.id} 「#{issue.subject}」가 등록되었습니다."
    SlackChannelMapper.send_message(project_channel, message)
  end

  # 2. 담당자에게 DM
  if issue.assigned_to&.is_a?(User)
    dm_message = "#{issue.assigned_to.name}님, 새로운 일감이 배정되었습니다.\n" \
                 "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}"
    SlackUserMapper.send_dm_to_user(issue.assigned_to, dm_message)
  end
end

# ============================================
# 예시 2: 그룹 채널 + 개별 DM
# ============================================
def example_group_channel_and_individual_dms
  group = Group.find_by(lastname: '개발팀')
  channel_name = 'dev-team'

  # 그룹 채널에 전체 공지
  team_message = "이번 주 스프린트 일감을 확인해주세요."
  SlackChannelMapper.send_message(channel_name, team_message)

  # 각 팀원에게 개인 할당 일감 DM
  group.users.active.each do |user|
    assigned_issues = Issue.open
                           .where(assigned_to: user)
                           .where('due_date <= ?', Date.current + 7.days)

    if assigned_issues.any?
      message = "#{user.name}님의 이번 주 일감 #{assigned_issues.size}건:\n"
      assigned_issues.limit(5).each do |issue|
        message += "- ##{issue.id} #{issue.subject}\n"
      end

      SlackUserMapper.send_dm_to_user(user, message)
    end
  end
end

# ============================================
# 예시 3: 우선순위에 따른 채널 라우팅
# ============================================
def example_priority_based_routing
  issue = Issue.find(1234)

  case issue.priority_id
  when 5, 6  # Urgent, Immediate
    # 긴급 채널 + 담당자 DM + 팀장 DM
    SlackChannelMapper.send_message('urgent', "🚨 긴급 일감 ##{issue.id}")

    SlackUserMapper.send_dm_to_user(issue.assigned_to, "긴급 일감이 배정되었습니다!")

    # 팀장에게도 알림
    team_leader = User.find_by(login: 'team.leader')
    SlackUserMapper.send_dm_to_user(team_leader, "긴급 일감 ##{issue.id} 확인 필요")

  when 4  # High
    # 고우선순위 채널 + 담당자 DM
    SlackChannelMapper.send_message('high-priority', "⚠️ 높은 우선순위 ##{issue.id}")
    SlackUserMapper.send_dm_to_user(issue.assigned_to, "높은 우선순위 일감입니다.")

  else
    # 일반 채널만
    project_channel = "project-#{issue.project.identifier}"
    SlackChannelMapper.send_message(project_channel, "일감 ##{issue.id} 등록")
  end
end

# ============================================
# 예시 4: 마감 임박 일감 - 단계별 에스컬레이션
# ============================================
def example_escalation_notification
  tomorrow = Date.tomorrow

  # 내일 마감인 일감
  due_tomorrow = Issue.where(due_date: tomorrow)
                      .where.not(status_id: IssueStatus.completed_ids)

  due_tomorrow.group_by(&:assigned_to).each do |user, issues|
    next unless user.is_a?(User)

    # 1단계: 담당자에게 DM
    message = "⏰ 내일 마감 예정 일감 #{issues.size}건"
    SlackUserMapper.send_dm_to_user(user, message)

    # 2단계: 일감이 3개 이상이면 팀 채널에도 공지
    if issues.size >= 3
      team_channel = user.groups.first&.lastname&.downcase
      if team_channel && SlackChannelMapper.get_channel_id(team_channel)
        team_message = "#{user.name}님의 내일 마감 일감이 #{issues.size}건입니다."
        SlackChannelMapper.send_message(team_channel, team_message)
      end
    end
  end

  # 지난 마감일 (에스컬레이션)
  overdue = Issue.where('due_date < ?', Date.current)
                 .where.not(status_id: IssueStatus.completed_ids + IssueStatus.implemented_ids)

  if overdue.any?
    # 전체 공지 채널에 알림
    SlackChannelMapper.send_message('general', "⚠️ 마감 지연 일감 #{overdue.size}건")

    # 각 담당자에게 DM
    overdue.group_by(&:assigned_to).each do |user, user_issues|
      next unless user.is_a?(User)

      message = "❗ 마감이 지난 일감 #{user_issues.size}건\n"
      user_issues.limit(5).each do |issue|
        days_overdue = (Date.current - issue.due_date).to_i
        message += "- ##{issue.id} (#{days_overdue}일 경과)\n"
      end

      SlackUserMapper.send_dm_to_user(user, message)
    end
  end
end

# ============================================
# 예시 5: 채널 자동 생성 및 사용자 초대 (Slack API)
# ============================================
def example_dynamic_channel_management
  project = Project.find_by(identifier: 'new-game')
  channel_name = "project-#{project.identifier}"

  # 채널이 없으면 생성 (Slack API 직접 호출 필요)
  unless SlackChannelMapper.get_channel_id(channel_name)
    create_slack_channel(channel_name, project.name)
    SlackChannelMapper.refresh_mapping  # 캐시 갱신
  end

  # 프로젝트 멤버들에게 DM으로 채널 안내
  project.members.each do |member|
    user = member.user
    next unless user.is_a?(User)

    message = "프로젝트 '#{project.name}'의 Slack 채널이 생성되었습니다.\n" \
              "##{channel_name} 채널에 참여해주세요."

    SlackUserMapper.send_dm_to_user(user, message)
  end

  # 채널에 환영 메시지
  welcome = "프로젝트 '#{project.name}' 채널에 오신 것을 환영합니다!"
  SlackChannelMapper.send_message(channel_name, welcome)
end

def create_slack_channel(name, description)
  token = Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_token']
  # Slack API conversations.create 호출
  # 구현 생략 (필요 시 추가)
end

# ============================================
# 예시 6: 일일 리포트 - 채널 요약 + 개인 DM
# ============================================
def example_daily_report
  # 전체 요약을 general 채널에
  total_open = Issue.open.count
  total_closed_today = Issue.where(closed_on: Date.current.all_day).count

  summary = "📊 금일 일감 현황\n" \
            "- 진행중: #{total_open}건\n" \
            "- 오늘 완료: #{total_closed_today}건"

  SlackChannelMapper.send_message('general', summary)

  # 각 활성 사용자에게 개인 통계 DM
  User.active.each do |user|
    user_open = Issue.open.where(assigned_to: user).count
    user_closed_today = Issue.where(assigned_to: user, closed_on: Date.current.all_day).count

    next if user_open.zero? && user_closed_today.zero?

    personal_summary = "#{user.name}님의 금일 현황\n" \
                      "- 진행중: #{user_open}건\n" \
                      "- 오늘 완료: #{user_closed_today}건"

    SlackUserMapper.send_dm_to_user(user, personal_summary)
  end
end

# ============================================
# 예시 7: 멘션 스타일 메시지 (채널에 사용자 멘션)
# ============================================
def example_mention_in_channel
  issue = Issue.find(1234)
  assignee = issue.assigned_to

  return unless assignee.is_a?(User)

  # Slack 사용자 ID 조회
  slack_user_id = SlackUserMapper.get_slack_user_id(assignee.login)

  if slack_user_id
    # 채널에 멘션이 포함된 메시지
    mention_text = "<@#{slack_user_id}> 일감 ##{issue.id} 확인 부탁드립니다."

    project_channel = "project-#{issue.project.identifier}"
    SlackChannelMapper.send_message(project_channel, mention_text)
  else
    # Slack 매핑이 없으면 DM으로 대체
    SlackUserMapper.send_dm_to_user(assignee, "일감 ##{issue.id} 확인 부탁드립니다.")
  end
end

# ============================================
# 예시 8: 조건부 알림 전략
# ============================================
def example_conditional_notification_strategy
  issue = Issue.find(1234)

  # 알림 전략 결정
  notification_strategy = determine_notification_strategy(issue)

  case notification_strategy
  when :silent
    # 알림 없음
    Rails.logger.info "조용한 알림: ##{issue.id}"

  when :dm_only
    # DM만
    SlackUserMapper.send_dm_to_user(issue.assigned_to, "일감 업데이트")

  when :channel_only
    # 채널만
    channel = find_appropriate_channel(issue)
    SlackChannelMapper.send_message(channel, "일감 ##{issue.id} 업데이트")

  when :both
    # 채널 + DM
    channel = find_appropriate_channel(issue)
    SlackChannelMapper.send_message(channel, "일감 ##{issue.id} 업데이트")
    SlackUserMapper.send_dm_to_user(issue.assigned_to, "일감이 업데이트되었습니다.")

  when :escalate
    # 에스컬레이션: 긴급 채널 + 담당자 DM + 관리자 DM
    SlackChannelMapper.send_message('urgent', "🚨 긴급: ##{issue.id}")
    SlackUserMapper.send_dm_to_user(issue.assigned_to, "긴급 확인 필요")

    admins = User.active.where(admin: true)
    admins.each do |admin|
      SlackUserMapper.send_dm_to_user(admin, "긴급 일감 ##{issue.id} 확인")
    end
  end
end

def determine_notification_strategy(issue)
  return :silent if issue.is_discarded? || issue.is_postponed?
  return :escalate if issue.priority_id >= 5 && issue.due_date && issue.due_date < Date.current
  return :both if issue.priority_id >= 4
  return :dm_only if issue.is_private?
  :channel_only
end

def find_appropriate_channel(issue)
  # 프로젝트 채널 우선, 없으면 일반 채널
  project_channel = "project-#{issue.project.identifier}"
  SlackChannelMapper.get_channel_id(project_channel) ? project_channel : 'general'
end

# ============================================
# 예시 9: Rich Text 블록으로 채널과 DM 통합
# ============================================
def example_rich_text_multi_destination
  issues = Issue.where(due_date: Date.tomorrow).open

  # Rich text 블록 생성
  elements = [
    {
      'type' => 'rich_text_section',
      'elements' => [
        {
          'type' => 'text',
          'text' => "내일 마감 일감 #{issues.size}건\n\n",
          'style' => { 'bold' => true }
        }
      ]
    }
  ]

  issues.each do |issue|
    slack_user_id = SlackUserMapper.get_slack_user_id(issue.assigned_to.login)
    mention = slack_user_id ? "<@#{slack_user_id}>" : issue.assigned_to.name

    elements << {
      'type' => 'rich_text_list',
      'style' => 'bullet',
      'elements' => [
        {
          'type' => 'rich_text_section',
          'elements' => [
            {
              'type' => 'link',
              'url' => "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}",
              'text' => "##{issue.id} #{issue.subject}"
            },
            {
              'type' => 'text',
              'text' => " - #{mention}"
            }
          ]
        }
      ]
    }
  end

  message_block = {
    'type' => 'rich_text',
    'elements' => elements
  }

  # 1. 전체 채널에 공지
  SlackChannelMapper.send_message('general', message_block)

  # 2. 각 담당자에게 개인 DM (본인 일감만)
  issues.group_by(&:assigned_to).each do |user, user_issues|
    next unless user.is_a?(User)

    personal_elements = [
      {
        'type' => 'rich_text_section',
        'elements' => [
          {
            'type' => 'text',
            'text' => "내일 마감 예정 일감 #{user_issues.size}건\n\n",
            'style' => { 'bold' => true }
          }
        ]
      }
    ]

    user_issues.each do |issue|
      personal_elements << {
        'type' => 'rich_text_list',
        'style' => 'bullet',
        'elements' => [
          {
            'type' => 'rich_text_section',
            'elements' => [
              {
                'type' => 'link',
                'url' => "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}",
                'text' => "##{issue.id} #{issue.subject}"
              }
            ]
          }
        ]
      }
    end

    personal_block = {
      'type' => 'rich_text',
      'elements' => personal_elements
    }

    SlackUserMapper.send_dm_to_user(user, personal_block)
  end
end

# ============================================
# 예시 10: TxReminderRefactored 개선 예시
# ============================================
module TxReminderRefactored
  # 기존 하드코딩된 채널 ID를 이름으로 변경
  def self.send_team_reminder_improved(team_config)
    # 채널 이름으로 ID 조회
    channel_name = team_config['channel_name']
    channel_id = SlackChannelMapper.get_channel_id(channel_name)

    unless channel_id
      Rails.logger.warn "채널을 찾을 수 없습니다: #{channel_name}"
      return
    end

    # 기존 로직...
    query_builder = IssueQuery.new(team_config)
    queries = query_builder.execute_enabled_queries

    queries.each_with_index do |query, idx|
      # 메시지 생성...
      message = build_reminder_message(query)

      # 1. 팀 채널에 전체 공지
      SlackChannelMapper.send_message(channel_name, message)

      # 2. 개별 사용자에게 필터링된 DM
      send_personalized_dms(query, team_config['user_ids'])
    end
  end

  def self.send_personalized_dms(query, user_ids)
    results = query.is_a?(ActiveRecord::Relation) ? query.to_a : query

    # 사용자별로 그룹핑
    results.group_by { |item| item['userid'] }.each do |user_id, user_items|
      next unless user_ids.include?(user_id)

      user = User.find_by(id: user_id)
      next unless user

      # 개인화된 메시지 생성
      personal_message = build_personal_message(user, user_items)

      # DM 전송
      SlackUserMapper.send_dm_to_user(user, personal_message)
    end
  end

  def self.build_personal_message(user, items)
    elements = [
      {
        'type' => 'rich_text_section',
        'elements' => [
          {
            'type' => 'text',
            'text' => "#{user.name}님의 확인이 필요한 일감 #{items.size}건\n\n",
            'style' => { 'bold' => true }
          }
        ]
      }
    ]

    items.each do |item|
      elements << create_issue_list_element(item)
    end

    {
      'type' => 'rich_text',
      'elements' => elements
    }
  end
end

# ============================================
# 실행
# ============================================
if __FILE__ == $PROGRAM_NAME
  # 원하는 예시를 주석 해제하여 실행
  # example_notify_channel_and_assignee
  # example_escalation_notification
  # example_daily_report
end
