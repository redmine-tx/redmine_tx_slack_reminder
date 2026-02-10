#!/usr/bin/env ruby
# frozen_string_literal: true

# SlackUserMapper 사용 예시

# 레드마인 환경 로드
require File.expand_path('../../../config/environment', __dir__)

# ============================================
# 예시 1: 단일 사용자에게 DM 전송
# ============================================
def example_send_single_dm
  login = 'john.doe'  # Redmine 로그인명
  message = '안녕하세요! 확인이 필요한 일감이 있습니다.'

  result = SlackUserMapper.send_dm(login, message)

  if result
    puts "#{login}에게 메시지 전송 완료"
  else
    puts "#{login}에게 메시지 전송 실패"
  end
end

# ============================================
# 예시 2: User 객체로 DM 전송
# ============================================
def example_send_dm_with_user_object
  user = User.find_by(login: 'john.doe')

  if user
    message = "#{user.name}님, 일감 확인이 필요합니다."
    SlackUserMapper.send_dm_to_user(user, message)
  end
end

# ============================================
# 예시 3: 일감 담당자에게 알림
# ============================================
def example_notify_issue_assignee
  issue = Issue.find(1234)

  if issue.assigned_to&.is_a?(User)
    message = <<~MSG
      일감 ##{issue.id} 「#{issue.subject}」
      마감일: #{issue.due_date}
      #{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}
    MSG

    SlackUserMapper.send_dm_to_user(issue.assigned_to, message)
  end
end

# ============================================
# 예시 4: Rich Text 블록으로 DM 전송
# ============================================
def example_send_rich_text_dm
  login = 'john.doe'
  issue = Issue.find(1234)

  message_block = {
    'type' => 'rich_text',
    'elements' => [
      {
        'type' => 'rich_text_section',
        'elements' => [
          {
            'type' => 'text',
            'text' => '확인이 필요한 일감: ',
            'style' => { 'bold' => true }
          },
          {
            'type' => 'link',
            'url' => "#{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}",
            'text' => "##{issue.id} #{issue.subject}"
          }
        ]
      },
      {
        'type' => 'rich_text_section',
        'elements' => [
          {
            'type' => 'text',
            'text' => "\n마감일: #{issue.due_date}"
          }
        ]
      }
    ]
  }

  SlackUserMapper.send_dm(login, message_block)
end

# ============================================
# 예시 5: 마감 임박 일감 담당자들에게 알림
# ============================================
def example_notify_upcoming_due_issues
  tomorrow = Date.tomorrow

  # 내일 마감인 일감들 조회
  issues = Issue.where(due_date: tomorrow)
               .where.not(status_id: IssueStatus.completed_ids + IssueStatus.discarded_ids)

  # 담당자별로 그룹핑
  issues.group_by(&:assigned_to).each do |user, user_issues|
    next unless user.is_a?(User)

    # Rich text 블록 생성
    elements = [
      {
        'type' => 'rich_text_section',
        'elements' => [
          {
            'type' => 'text',
            'text' => "내일 마감 예정인 일감이 #{user_issues.size}건 있습니다.\n\n",
            'style' => { 'bold' => true }
          }
        ]
      }
    ]

    # 각 일감을 리스트로 추가
    user_issues.each do |issue|
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

    SlackUserMapper.send_dm_to_user(user, message_block)

    puts "#{user.name}에게 내일 마감 일감 #{user_issues.size}건 알림 전송"
  end
end

# ============================================
# 예시 6: 특정 그룹 사용자들에게 공지
# ============================================
def example_notify_group_members
  group = Group.find_by(lastname: '개발팀')

  if group
    message = '이번 주 주요 일감을 확인해주세요.'

    group.users.active.each do |user|
      result = SlackUserMapper.send_dm_to_user(user, message)

      if result
        puts "#{user.name}에게 전송 완료"
      else
        puts "#{user.name}에게 전송 실패 (Slack 미매핑)"
      end

      # Rate limit 고려
      sleep 0.5
    end
  end
end

# ============================================
# 예시 7: TxReminderRefactored에 통합
# ============================================
module TxReminderRefactored
  # 개인별 DM 알림 추가 예시
  def self.send_personal_reminders
    return if holiday_today?

    # 오늘 시작하거나 마감인 일감들
    today = Date.current

    issues = Issue.joins(:assigned_to, :status)
                  .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
                  .where(
                    Issue.arel_table[:start_date].eq(today)
                    .or(Issue.arel_table[:due_date].eq(today))
                  )
                  .where(issue_statuses: { is_closed: false })

    # 사용자별로 그룹핑
    issues.group_by(&:assigned_to).each do |user, user_issues|
      next unless user.is_a?(User)

      # 시작일감과 마감일감 분리
      start_issues = user_issues.select { |i| i.start_date == today }
      due_issues = user_issues.select { |i| i.due_date == today }

      # 메시지 생성
      elements = []

      if start_issues.any?
        elements << {
          'type' => 'rich_text_section',
          'elements' => [
            {
              'type' => 'text',
              'text' => "오늘 시작 일감 #{start_issues.size}건\n",
              'style' => { 'bold' => true }
            }
          ]
        }

        start_issues.each do |issue|
          elements << create_issue_list_element(issue)
        end
      end

      if due_issues.any?
        elements << {
          'type' => 'rich_text_section',
          'elements' => [
            {
              'type' => 'text',
              'text' => "\n오늘 마감 일감 #{due_issues.size}건\n",
              'style' => { 'bold' => true }
            }
          ]
        }

        due_issues.each do |issue|
          elements << create_issue_list_element(issue)
        end
      end

      message_block = {
        'type' => 'rich_text',
        'elements' => elements
      }

      SlackUserMapper.send_dm_to_user(user, message_block)

      Rails.logger.info "개인 알림 전송: #{user.name} (시작 #{start_issues.size}건, 마감 #{due_issues.size}건)"
    end
  end

  def self.create_issue_list_element(issue)
    {
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
              'text' => " (#{issue.status.name})"
            }
          ]
        }
      ]
    }
  end
end

# ============================================
# 예시 8: 매핑 정보 조회 및 관리
# ============================================
def example_manage_mapping
  # 모든 매핑 정보 조회
  mappings = SlackUserMapper.all_mappings
  puts "총 #{mappings.size}명 매핑됨"

  # 특정 사용자 조회
  slack_id = SlackUserMapper.get_slack_user_id('john.doe')
  puts "john.doe의 Slack ID: #{slack_id}"

  # 매핑 강제 갱신
  SlackUserMapper.refresh_mapping

  # Redmine 활성 사용자와 비교
  active_users = User.active
  mapped_count = active_users.count { |u| SlackUserMapper.get_slack_user_id(u.login) }
  puts "활성 사용자 #{active_users.size}명 중 #{mapped_count}명이 Slack에 매핑됨"
end

# ============================================
# 실행 예시
# ============================================
if __FILE__ == $PROGRAM_NAME
  # 사용할 예시 함수를 주석 해제하여 실행
  # example_send_single_dm
  # example_notify_upcoming_due_issues
  # example_manage_mapping
end
