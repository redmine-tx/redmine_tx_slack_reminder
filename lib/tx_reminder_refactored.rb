#!/usr/bin/env ruby
# frozen_string_literal: true

# 레드마인 환경 로드
require File.expand_path('../../../config/environment', __dir__)

require 'json'
require 'net/http'
require 'uri'
require 'date'

module TxReminderRefactored
  # 일감 필터링 기준 날짜 (2025년 1월 1일 이후 생성된 일감만 대상)
  ISSUE_CREATED_AFTER = Date.new(2025, 1, 1)

  # 제외할 트래커 ID 목록
  def self.exclude_tracker_ids
    ( Tracker.exception_trackers_ids + Tracker.roadmap_trackers_ids + Tracker.sidejob_trackers_ids + Tracker.bug_trackers_ids ).uniq
  end

  # 메모 커스텀 필드 ID를 동적으로 조회
  def self.memo_custom_field_id
    @memo_cf_id ||= CustomField.find_by(name: '메모')&.id
  end

  # 쿼리 타입 정의
  QUERY_TYPES = {
    # 기본 쿼리들
    basic: {
      today_issues: '오늘 시작 또는 오늘 완료되어야 하는 일감',
      upcoming_due_issues: 'D-1, D-3 마감예정 일감',
      overdue_new_issues: '시작일 지났음에도 상태가 신규',
      overdue_issues: '완료기한이 지난 일감',
      category_missing_issues: '범주 기입이 필요한 일감',
      team_status_issues: '일감 상태가 팀 상태로 방치',
      no_dates_in_progress: '날짜 기입없이 진행중인 일감'
    },
    # 메인 모드 쿼리들
    main: {
      main_upcoming_due_issues: '3일이내 마감예정 일감',
      main_overdue_new_issues: '시작일 지났음에도 상태가 신규',
      main_overdue_issues: '완료기한이 지난 일감',
      main_category_missing: '범주 기입이 필요한 일감',
      main_team_status: '일감 상태가 팀 상태로 방치',
      main_no_dates: '진행중이지만 날짜 미기입'
    },
    # 커스텀 쿼리들 (레벨팀, 프로그램실)
    custom: {
      next_week_start_issues: '차 주 시작일감',
      custom_overdue_new_issues: '시작일이 지났음에도 상태가 신규',
      delayed_issues: '지연 일감'
    },
    # 어제 업무 쿼리
    yesterday: {
      yesterday_issues: '어제 상태 변경 진행한 일감'
    }
  }.freeze

  # 팀별 설정 정의
  TEAM_CONFIGS = {
    'dajin' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:40',
      'user_ids' => [46, 101, 141, 167, 327, 140, 524, 558],
      'team_name' => '비전팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'dasl' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:27',
      'user_ids' => [405, 77, 487, 522, 519, 525, 584, 590],
      'team_name' => '시나리오팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'eunyong' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:43',
      'user_ids' => [134, 37, 99, 79, 475, 476, 516, 530, 572],
      'team_name' => '시스템팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'jihoon' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:17',
      'user_ids' => [122, 236, 196, 358, 284, 402, 345, 373, 471, 268, 66, 386, 171, 312, 526, 531, 575],
      'team_name' => '전투영웅팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'live' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:42',
      'user_ids' => [498, 499, 528, 541, 560, 609],
      'team_name' => '라이브팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'level' => {
      'channel' => 'C08FT35S2U8',
      'notification_time' => '09:41',
      'user_ids' => [133, 346, 497, 89, 149, 511, 586, 542],
      'team_name' => '레벨팀',
      'enabled_queries' => [:next_week_start_issues, :custom_overdue_new_issues, :delayed_issues],
      'query_type' => :custom
    },
    'team' => {
      'channel' => 'C07DYMSL02D',
      'notification_time' => '09:45',
      'user_ids' => [415, 382, 21, 317, 179, 116, 147, 96, 113, 474, 434, 82, 514, 17, 34, 70],
      'team_name' => '프로그램실',
      'enabled_queries' => [:next_week_start_issues, :custom_overdue_new_issues, :delayed_issues],
      'query_type' => :custom
    },
    'ui' => {
      'channel' => 'C06GW9XCTB4',
      'notification_time' => '09:23',
      'user_ids' => [59, 161, 503, 534, 544, 589],
      'team_name' => 'UI팀',
      'enabled_queries' => [:today_issues, :upcoming_due_issues, :overdue_new_issues, :overdue_issues],
      'query_type' => :basic
    },
    'yesterday' => {
      'channel' => 'C06F6AZF2H2',
      'notification_time' => '09:25',
      'user_ids' => [415, 382, 21, 317, 179, 116, 147, 96, 113, 474, 434, 82, 514, 17, 34, 70, 133, 346, 18, 135, 497, 89, 149, 511, 586, 542, 46, 101, 141, 167, 327, 140, 524, 558, 59, 161, 503, 534, 544, 405, 77, 487, 522, 519, 525, 584, 134, 37, 99, 79, 475, 476, 516, 530, 572, 498, 499, 528, 541, 560, 122, 236, 196, 358, 284, 402, 345, 373, 471, 268, 66, 386, 171, 312, 526, 531, 575],
      'team_name' => '어제업무팀',
      'enabled_queries' => [:yesterday_issues],
      'query_type' => :yesterday
    },
    'main' => {
      'channel' => 'D05TWL44DQT',
      'notification_time' => '10:00',
      'user_ids' => [],
      'team_name' => '전체',
      'enabled_queries' => [:main_upcoming_due_issues, :main_overdue_new_issues, :main_overdue_issues, :main_category_missing, :main_team_status, :main_no_dates],
      'query_type' => :main
    }
  }.freeze

  # 공통 상수
  MAX_DATA_COUNT = 50
  MAXLENG = 100
  #SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/TXXXXX/BXXXXX/XXXXXXXXXX'
  USERNAME = '리마인더'

  # 글로벌 변수
  $str_today = ''

  # 팀 멤버 정의
  # TEAM_MEMBERS = [
  #   { '프로그램실' => [415, 382, 21, 317, 179, 116, 147, 96, 113, 474, 434, 82, 514, 17, 34, 70] },
  #   { '영웅팀' => [122, 236, 196, 358, 284, 402, 345, 373] },
  #   { '전투컨텐츠팀' => [471, 268, 66, 386, 171, 312, 526, 531, 575] },
  #   { '레벨팀' => [133, 346, 18, 135, 497, 89, 149, 511, 586, 542] },
  #   { '비전팀' => [46, 101, 141, 167, 327, 140, 524, 558] },
  #   { '시나리오팀' => [77, 487, 522, 519, 525, 584] },
  #   { 'UI팀' => [161, 503, 534, 544] },
  #   { '시스템팀' => [134, 37, 99, 79, 475, 476, 516, 530, 572] },
  #   { '라이브팀' => [498, 499, 528, 541, 560] },
  #   { '플밍' => [415, 382, 21, 317, 179, 116, 147, 96, 113, 474, 434, 82, 514, 17, 34, 70] }
  # ].freeze

  class IssueQuery
    attr_reader :config

    def initialize(config)
      @config = config
    end

    # 설정된 쿼리들만 실행
    def execute_enabled_queries
      enabled_queries = config['enabled_queries'] || []
      user_ids = config['user_ids']
      
      results = []
      
      enabled_queries.each do |query_key|
        query_result = case query_key
                      # 기본 쿼리들
                      when :today_issues
                        today_issues_query(user_ids)
                      when :upcoming_due_issues
                        upcoming_due_issues_query(user_ids)
                      when :overdue_new_issues
                        overdue_new_issues_query(user_ids)
                      when :overdue_issues
                        overdue_issues_query(user_ids)
                      when :category_missing_issues
                        category_missing_issues_query
                      when :team_status_issues
                        team_status_issues_query
                      when :no_dates_in_progress
                        no_dates_in_progress_query(user_ids)
                      
                      # 메인 모드 쿼리들
                      when :main_upcoming_due_issues
                        excluded_user_ids = [] #[254, 54, 55, 56, 57, 58, 255, 256, 300, 349]
                        main_upcoming_due_issues_query(excluded_user_ids)
                      when :main_overdue_new_issues
                        excluded_user_ids = [] #[254, 54, 55, 56, 57, 58, 255, 256, 300, 349]
                        main_overdue_new_issues_query(excluded_user_ids)
                      when :main_overdue_issues
                        main_overdue_issues_query
                      when :main_category_missing
                        main_category_missing_query
                      when :main_team_status
                        main_team_status_query
                      when :main_no_dates
                        main_no_dates_query
                      
                      # 커스텀 쿼리들
                      when :next_week_start_issues
                        next_week_start_issues_query(user_ids)
                      when :custom_overdue_new_issues
                        custom_overdue_new_issues_query(user_ids)
                      when :delayed_issues
                        delayed_issues_query(user_ids)
                      
                      # 어제 업무 쿼리
                      when :yesterday_issues
                        day_of_week = Time.now.wday
                        if day_of_week == 1  # 월요일
                          yesterday_issues_query_weekend(user_ids)
                        else
                          yesterday_issues_query(user_ids)
                        end
                      
                      else
                        puts "알 수 없는 쿼리 타입: #{query_key}"
                        []
                      end
        
        results << query_result
      end
      
      results
    end

    # 쿼리 이름들 반환
    def get_query_names
      enabled_queries = config['enabled_queries'] || []
      query_type = config['query_type'] || :basic
      
      enabled_queries.map do |query_key|
        QUERY_TYPES[query_type][query_key] || query_key.to_s
      end
    end

    private

    # 오늘 시작 또는 오늘 완료되어야 하는 일감
    def today_issues_query(user_ids)
      today = Date.current

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(
             Issue.arel_table[:start_date].eq(today)
             .or(Issue.arel_table[:due_date].eq(today))
           )
           .where(issue_statuses: { is_closed: false })
           .where(assigned_to_id: user_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
           .order(:status_id, :due_date)
    end

    # D-1, D-3 마감예정 일감
    def upcoming_due_issues_query(user_ids)
      tomorrow = Date.current + 1.day
      three_days_later = Date.current + 3.days

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(
             Issue.arel_table[:due_date].eq(tomorrow)
             .or(Issue.arel_table[:due_date].eq(three_days_later))
           )
           .where(issue_statuses: { is_closed: false })
           .where(assigned_to_id: user_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
           .where.not(status_id: IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .order(:status_id, :due_date)
    end

    # 시작일 지났음에도 상태가 신규
    def overdue_new_issues_query(user_ids)
      yesterday = Date.current - 1.day

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where.not(start_date: nil)
           .where('start_date < ?', yesterday)
           .where(issue_statuses: { is_closed: false })
           .where(status_id: IssueStatus.new_ids)
           .where(assigned_to_id: user_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
           .order(:start_date)
    end

    # 완료기한이 지난 일감
    def overdue_issues_query(user_ids)
      yesterday = Date.current - 1.day

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where('due_date < ?', yesterday)
           .where(issue_statuses: { is_closed: false })
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .where( status_id: IssueStatus.in_progress_ids + IssueStatus.new_ids )
           .where(assigned_to_id: user_ids)
           .order(:status_id, :due_date)
    end

    # 범주 기입이 필요한 일감
    def category_missing_issues_query
      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(issue_statuses: { is_closed: false })
           #.where(groups_users: { group_id: [254, 54, 55, 56, 57, 58, 255, 256, 300] })
           .where(category_id: nil)
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .order(:status_id, :due_date)
    end

    # 일감 상태가 팀 상태로 방치
    def team_status_issues_query
      Issue.joins(:assigned_to, :status, :fixed_version)
           .select(select_fields_with_version)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(issue_statuses: { is_closed: false })
           .where('users.firstname = ?', '')
           .where.not(fixed_version_id: nil)
           .where(status_id: IssueStatus.in_progress_ids + IssueStatus.new_ids)
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
    end

    # 날짜 기입없이 진행중인 일감
    def no_dates_in_progress_query(user_ids)
      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .left_joins(custom_values: :custom_field)
           .select(select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(
             Issue.arel_table[:start_date].eq(nil)
             .or(Issue.arel_table[:due_date].eq(nil))
           )
           .where(issue_statuses: { is_closed: false })
           .where(status_id: IssueStatus.in_progress_ids)
           .where.not(tracker_id: TxReminderRefactored.exclude_tracker_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
    end

    # 메인 모드 - 3일이내 마감예정 일감
    def main_upcoming_due_issues_query(excluded_user_ids)
      yesterday = Date.current - 1.day
      three_days_later = Date.current + 3.days

      Issue.joins(:assigned_to, :status)
           .select(main_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where('due_date > ? AND due_date < ?', yesterday, three_days_later)
           .where.not(assigned_to_id: excluded_user_ids)
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .order(:status_id, :due_date)
    end

    # 메인 모드 - 시작일 지났음에도 상태가 신규
    def main_overdue_new_issues_query(excluded_user_ids)
      tomorrow = Date.current + 1.day

      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .select(main_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where.not(start_date: nil)
           .where('start_date < ?', tomorrow)
           .where(status_id: IssueStatus.new_ids)
           .where.not(assigned_to_id: excluded_user_ids)
           .order(:status_id, :start_date)
    end

    # 메인 모드 - 완료기한이 지난 일감
    def main_overdue_issues_query
      tomorrow = Date.current + 1.day

      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .select(main_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where('due_date < ?', tomorrow)
           #.where.not(groups_users: { group_id: [254, 54, 55, 56, 57, 58, 255, 256, 300] })
           #.where.not(assigned_to_id: [449, 348])
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .order(:status_id, :due_date)
    end

    # 메인 모드 - 범주 기입이 필요한 일감
    def main_category_missing_query
      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .select(main_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(issue_statuses: { is_closed: false })
           #.where(groups_users: { group_id: [254, 54, 55, 56, 57, 58, 255, 256, 300] })
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .where(category_id: nil)
           .order(:status_id, :due_date)
    end

    # 메인 모드 - 일감 상태가 팀 상태로 방치
    def main_team_status_query
      Issue.joins(:assigned_to, :status, :fixed_version)
           .select(main_select_fields_with_version)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where('users.firstname = ?', '')
           .where.not(fixed_version_id: nil)
           .where(status_id: IssueStatus.in_progress_ids + IssueStatus.new_ids)
           .order(:status_id, :due_date)
    end

    # 메인 모드 - 진행중이지만 날짜 미기입
    def main_no_dates_query
      Issue.joins(:assigned_to, :status)
           .joins('JOIN groups_users ON issues.assigned_to_id = groups_users.user_id')
           .select(main_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where( due_date: nil )
           .where(status_id: IssueStatus.in_progress_ids)
           .where.not(tracker_id: TxReminderRefactored.exclude_tracker_ids)
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .order(:status_id, :start_date)
    end

    # 어제 업무 쿼리
    def yesterday_issues_query(user_ids)
      yesterday_start = Date.current.beginning_of_day - 1.day
      yesterday_end = Date.current.beginning_of_day
      status_ids = (IssueStatus.new_ids + IssueStatus.in_progress_ids).map(&:to_s).map { |id| "'#{id}'" }.join(', ')

      Issue.joins(:assigned_to, :status)
           .joins('JOIN journals ON journals.journalized_id = issues.id AND journals.journalized_type = "Issue"')
           .joins('JOIN journal_details ON journal_details.journal_id = journals.id')
           .select(yesterday_select_fields)
           .where('journals.created_on >= ? AND journals.created_on < ?', yesterday_start, yesterday_end)
           .where(journal_details: { property: 'attr', prop_key: 'status_id' })
           .where(Arel.sql("journal_details.old_value IN (#{status_ids}) OR journal_details.value IN (#{status_ids})"))
           .where('journals.user_id IN (?)', user_ids)
    end

    # 어제 업무 쿼리 (주말포함 - 월요일용)
    def yesterday_issues_query_weekend(user_ids)
      three_days_ago = Date.current.beginning_of_day - 3.days
      today_start = Date.current.beginning_of_day
      status_ids = (IssueStatus.new_ids + IssueStatus.in_progress_ids).map(&:to_s).map { |id| "'#{id}'" }.join(', ')

      Issue.joins(:assigned_to, :status)
           .joins('JOIN journals ON journals.journalized_id = issues.id AND journals.journalized_type = "Issue"')
           .joins('JOIN journal_details ON journal_details.journal_id = journals.id')
           .select(yesterday_select_fields)
           .where('journals.created_on >= ? AND journals.created_on < ?', three_days_ago, today_start)
           .where(journal_details: { property: 'attr', prop_key: 'status_id' })
           .where(Arel.sql("journal_details.old_value IN (#{status_ids}) OR journal_details.value IN (#{status_ids})"))
           .where('journals.user_id IN (?)', user_ids)
    end

    # 커스텀 쿼리 - 차 주 시작일감
    def next_week_start_issues_query(user_ids)
      today = Date.current
      next_monday = today.beginning_of_week + 1.week
      next_friday = next_monday + 4.days

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(custom_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where(start_date: next_monday..next_friday)
           .where(issue_statuses: { is_closed: false })
           .where(assigned_to_id: user_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
           .order(Arel.sql('CONCAT(users.lastname, users.firstname)'), :start_date)
    end

    # 커스텀 쿼리 - 시작일이 지났음에도 상태가 신규
    def custom_overdue_new_issues_query(user_ids)
      yesterday = Date.current - 1.day

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(custom_select_fields)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where.not(start_date: nil)
           .where('start_date < ?', yesterday)
           .where(issue_statuses: { is_closed: false })
           .where(status_id: IssueStatus.new_ids)
           .where(assigned_to_id: user_ids)
           .where(custom_values: { custom_field_id: [TxReminderRefactored.memo_custom_field_id, nil] })
           .where(Arel.sql('custom_values.id > 700000 OR custom_values.id IS NULL'))
           .where(Arel.sql('LENGTH(custom_values.value) > 0 OR custom_values.value IS NULL'))
           .order(Arel.sql('CONCAT(users.lastname, users.firstname)'), :start_date)
    end

    # 커스텀 쿼리 - 지연 일감
    def delayed_issues_query(user_ids)
      yesterday = Date.current - 1.day

      Issue.joins(:assigned_to, :status)
           .left_joins(custom_values: :custom_field)
           .select(custom_select_fields_with_delay)
           .where('issues.created_on >= ?', ISSUE_CREATED_AFTER)
           .where('due_date < ?', yesterday)
           .where.not(status_id: IssueStatus.implemented_ids + IssueStatus.completed_ids + IssueStatus.discarded_ids + IssueStatus.postponed_ids)
           .where( status_id: IssueStatus.in_progress_ids )
           .where(assigned_to_id: user_ids)
           .order(Arel.sql('CONCAT(users.lastname, users.firstname)'), :due_date)
    end

    # 기본 SELECT 필드들
    def select_fields
      [
        Arel.sql('DISTINCT issues.id'),
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        Arel.sql('users.id as userid'),
        Arel.sql('custom_values.value')
      ].join(', ')
    end

    # 버전 포함 SELECT 필드들
    def select_fields_with_version
      [
        Arel.sql('DISTINCT issues.id'),
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        'versions.name',
        Arel.sql('users.id as userid')
      ].join(', ')
    end

    # 메인 모드 SELECT 필드들
    def main_select_fields
      [
        'issues.id',
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name')
      ].join(', ')
    end

    # 메인 모드 버전 포함 SELECT 필드들
    def main_select_fields_with_version
      [
        'issues.id',
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        'versions.name'
      ].join(', ')
    end

    # 어제 업무 SELECT 필드들
    def yesterday_select_fields
      [
        'issues.id',
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        Arel.sql('users.id as userid'),
        'journal_details.old_value',
        'issues.estimated_hours'
      ].join(', ')
    end

    # 커스텀 쿼리 SELECT 필드들
    def custom_select_fields
      [
        Arel.sql('DISTINCT issues.id'),
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        Arel.sql('users.id as userid'),
        Arel.sql('custom_values.value as version')
      ].join(', ')
    end

    # 지연일수 포함 커스텀 쿼리 SELECT 필드들
    def custom_select_fields_with_delay
      [
        Arel.sql('DISTINCT issues.id'),
        'issues.subject',
        'issues.start_date',
        'issues.due_date',
        Arel.sql('issue_statuses.name as status_name'),
        'users.login',
        'issues.status_id',
        'issues.updated_on',
        'issues.description',
        Arel.sql('CONCAT(users.lastname, users.firstname) as user_name'),
        Arel.sql('users.id as userid'),
        Arel.sql('custom_values.value as version'),
        Arel.sql('DATEDIFF(NOW(), issues.due_date) as delay_days')
      ].join(', ')
    end
  end

  class IssueProcessor
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def perform_task
      begin
        query_builder = IssueQuery.new(config)

        if config['query_type'] == :yesterday
          handle_yesterday_mode(query_builder)
        else
          handle_normal_mode(query_builder)
        end

        puts 'ActiveRecord 작업이 성공적으로 완료되었습니다.'
      rescue => error
        warn "ActiveRecord 작업 중 오류가 발생했습니다: #{error}"
        raise error
      end
    end

    private

    def handle_yesterday_mode(query_builder)
      queries = query_builder.execute_enabled_queries
      
      queries.each_with_index do |query, idx|
        results = query.is_a?(ActiveRecord::Relation) ? query.to_a : query
        processed_data = results.map { |item| process_item(item) }
        temp_data = processed_data.dup
        all_data = sort_data_by_team(temp_data)
        
        process_all_data(all_data, idx)
      end
    end

    def handle_normal_mode(query_builder)
      queries = query_builder.execute_enabled_queries

      queries.each_with_index do |query, idx|
        results = query.is_a?(ActiveRecord::Relation) ? query.to_a : query
        processed_data = results.map { |item| process_item(item) }
        
        all_data = if config['query_type'] == :main
                     temp_data = processed_data.dup
                     filter_objects_dup(temp_data)
                   else
                     temp_data = processed_data.dup
                     sort_data_by_team(temp_data)
                   end

        # pp all_data
        
        process_all_data(all_data, idx)
      end
    end

    # 아이템 처리 함수
    def process_item(item)
      # ActiveRecord 객체인 경우 attributes로 변환
      item_hash = item.is_a?(Hash) ? item : item.attributes

      due_date = get_md(item_hash['due_date'])
      start_date = get_md(item_hash['start_date'])
      updated = get_md(item_hash['updated_on'])
      url = "#{Setting.protocol}://#{Setting.host_name}/issues/#{item_hash['id']}"
      subj = text_length_check(item_hash['subject'], MAXLENG)
      sid = "@ #{item_hash['login']}"

      result = {
        'id' => item_hash['id'],
        'subject' => subj,
        'start_date' => start_date,
        'due_date' => due_date,
        'status_name' => item_hash['status_name'],
        'name' => item_hash['user_name'],
        'rmurl' => url,
        'loginid' => sid,
        'status_id' => item_hash['status_id'],
        'updated' => updated,
        'logid' => item_hash['journal_id'] || 0,
        'teamname' => '',
        'userid' => item_hash['userid'] || 0,
        'memo' => item_hash['value'] || item_hash['version']
      }

      # 지연일수가 있는 경우 추가
      result['delay_days'] = item_hash['delay_days'] if item_hash.key?('delay_days')

      result
    end

    # 팀별 데이터 정렬 함수
    def sort_data_by_team(all_data)
      sorted_data = {}

      get_team_members.each do |team_member|
        team = team_member.keys.first
        sorted_data[team] = []
      end

      all_data.each do |data|
        userid = data['userid']
        team = find_team_by_user_id(userid)
        data['teamname'] = team
        sorted_data[team].push(data) if team
      end

      sorted_data.each do |team, team_data|
        team_data.sort! { |a, b| a['userid'] <=> b['userid'] }
      end

      result_data = []
      sorted_data.each do |team, team_data|
        result_data.concat(team_data) if team_data.any?
      end

      result_data
    end

    # 팀 찾기 함수
    def find_team_by_user_id(userid)
      get_team_members.each do |team_member|
        team = team_member.keys.first
        member_ids = team_member[team]
        return team if member_ids.include?(userid)
      end
      nil
    end

    def get_team_members
      @team_members ||= Group.all.map do |group|
        { group.lastname => group.users.pluck(:id) }
      end
    end

    # 슬랙 메시지 처리 함수
    def process_all_data(all_data, type)
      total_data_count = all_data.length
      start_index = 0
      bfirst = true
      number = 0
      query_builder = IssueQuery.new(config)
      query_name_arr = query_builder.get_query_names
      titlesub = query_name_arr[type]
      
      now_team_name = ''
      now_user_name = ''

      while start_index < total_data_count
        end_index = [start_index + MAX_DATA_COUNT, total_data_count].min
        current_data = all_data[start_index...end_index]

        elements = []

        today = Time.now
        tod_year = today.year
        tod_month = format('%02d', today.month)
        tod_day = format('%02d', today.day)
        $str_today = "#{tod_year}-#{tod_month}-#{tod_day}"

                 todate = if config['query_type'] == :main
                     "오늘은 #{$str_today} \n"
                   elsif type == 0
                     "오늘은 #{$str_today} \n총 #{total_data_count}건의 일감이 확인되었네요. \n"
                   else
                     "총 #{total_data_count}건의 일감이 확인되었네요. \n"
                   end

        if bfirst
          elements.push({
            'type' => 'rich_text_section',
            'elements' => [
              {
                'type' => 'emoji',
                'name' => 'ham1'
              },
                             {
                 'type' => 'text',
                 'text' => todate,
                 'style' => {
                   'bold' => config['query_type'] == :main ? true : false
                 }
               },
              {
                'type' => 'emoji',
                'name' => 'date'
              },
                             {
                 'type' => 'text',
                 'text' => config['query_type'] == :main ? "#{titlesub} #{total_data_count}건" : titlesub.to_s,
                 'style' => {
                   'bold' => config['query_type'] == :main ? true : false
                 }
               }
            ]
          })
          bfirst = false
        end

        current_data.each do |props|
          number += 1
                     link_element = {
             'type' => 'link',
             'url' => props['rmurl'],
             'text' => config['query_type'] == :main ? "#{props['id']} #{props['subject']}" : "#{props['id']} #{props['subject']},",
             'style' => {
               'bold' => config['query_type'] == :main ? true : false
             }
           }
          
          memo = props['memo']
          
          text_element = if config['query_type'] == :yesterday
                {
                  'type' => 'text',
                  'text' => "상태: #{props['status_name']}, 완료일: #{props['due_date']}"
                }
              elsif config['query_type'] == :main
                {
                  'type' => 'text',
                  'text' => " #{props['name']}, 시작일 #{props['start_date']},완료일 #{props['due_date']}"
                }
              else
                # 팀별 특화 메시지 생성
                generate_team_specific_message(props, type, memo)
              end
          
          rich_text_section = {
            'type' => 'rich_text_section',
            'elements' => [link_element, text_element]
          }
          
          elements.push({
            'type' => 'rich_text_list',
            'style' => 'bullet',
            'elements' => [rich_text_section]
          })
        end
        
        msg = {
          'type' => 'rich_text',
          'elements' => elements
        }

        #puts msg
        TxReminderRefactored.send_slack_message(msg)
        
        start_index = end_index
      end
    end

    # 팀별 특화 메시지 생성
    def generate_team_specific_message(props, type, memo)
      if config['query_type'] == :custom
        # 레벨팀/프로그램실 메시지
        if type == 0 || type == 1
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " 시작일 #{props['start_date']}, 완료일 #{props['due_date']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " 시작일 #{props['start_date']}, 완료일 #{props['due_date']}"
            }
          end
        elsif type == 2
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " 시작일 #{props['start_date']},완료일 #{props['due_date']},(#{props['delay_days']}일 경과), 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " 시작일 #{props['start_date']},완료일 #{props['due_date']},(#{props['delay_days']}일 경과)"
            }
          end
        end
      else
        # 기본 팀 메시지
        case type
        when 0, 1
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 시작일 #{props['start_date']}, 완료일 #{props['due_date']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 시작일 #{props['start_date']}, 완료일 #{props['due_date']}"
            }
          end
        when 2
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 시작일 #{props['start_date']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 시작일 #{props['start_date']}"
            }
          end
        when 3
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " #{props['name']},완료일 #{props['due_date']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 완료일 #{props['due_date']}"
            }
          end
        when 5
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " #{props['name']}"
            }
          end
        else
          if memo && memo != ''
            return {
              'type' => 'text',
              'text' => " #{props['name']}, 시작일 #{props['start_date']},완료일 #{props['due_date']}, 메모: #{memo}"
            }
          else
            return {
              'type' => 'text',
              'text' => " #{props['name']}"
            }
          end
        end
      end
      
      {
        'type' => 'text',
        'text' => " #{props['name']}"
      }
    end

    



    # 유틸리티 함수들
    def text_length_check(str, len)
      return '' if !len || len <= 0
      
      return str if get_string_length(str) <= len

      sliced_str = ''
      current_length = 0
      
      str.each_char do |char|
        char_length = get_string_length(char)
        break if current_length + char_length > len
        
        sliced_str += char
        current_length += char_length
      end
      
      sliced_str + '...'
    end

    def get_string_length(str)
      str_length = 0
      str.each_char do |char|
        code = char.ord
        if code >= 0xac00 && code <= 0xd7af
          str_length += 2
        else
          str_length += 1
        end
      end
      str_length
    end

    def get_md(datestring)
      return '없음' unless datestring

      date_par = datestring.to_s.split('T')[0]
      yy, mm, dd = date_par.split('-')
      
      # 일부 파일에서는 날짜에 +1을 하는 로직이 있었음
      if config['add_day_to_date']
        dday = dd.to_i + 1
        last_day_of_month = Date.new(yy.to_i, mm.to_i, -1).day
        if dday > last_day_of_month
          dday = 1
          mm = mm.to_i + 1
        end
        formatted_day = dday < 10 ? format('0%d', dday) : dday.to_s
        return "#{mm}/#{formatted_day}"
      end
      
      "#{mm}/#{dd}"
    end

    def filter_objects_dup(arr)
      id_map = {}
      
      # 먼저 각 ID별로 최신 logid를 가진 객체를 찾음
      arr.each do |obj|
        if !id_map.key?(obj['id']) || obj['logid'] > id_map[obj['id']]['logid']
          id_map[obj['id']] = obj
        end
      end
      
      # 원래 배열 순서를 유지하면서 중복 제거
      # (이미 쿼리에서 정렬된 순서를 유지)
      seen_ids = {}
      arr.filter_map do |obj|
        id = obj['id']
        if !seen_ids.key?(id) && id_map[id] == obj
          seen_ids[id] = true
          obj
        end
      end
    end
  end

  # 휴일 확인 함수
  def self.holiday_today?
    # redmine_tx_more_calendar 플러그인을 사용하여 휴일 확인
    return Holiday.holiday?(Date.today)
  end

  # 스케줄 알림 함수
  def self.schedule_notification(config)
    current_time = Time.now
    current_hour = format('%02d', current_time.hour)
    current_minute = format('%02d', current_time.min)
    current_time_string = "#{current_hour}:#{current_minute}"
    
    # if config['notification_time'] == current_time_string
      is_holiday = holiday_today?
      unless is_holiday
        begin
          processor = IssueProcessor.new(config)
          processor.perform_task
          puts 'ActiveRecord 작업이 성공적으로 완료되었습니다.'
        rescue => error
          warn "ActiveRecord 작업 중 오류가 발생했습니다: #{error}"
        end
      end
    # end
  end

  # 메인 실행 함수
  def self.remind_group()

    return holiday_today?

    reminder_field = GroupCustomField.find_by(name: 'reminder_slack_channel_id')
    reminder_field = reminder_field ? Group.all.select { |group| 
      value = group.custom_field_value(reminder_field)
      value.present?
    }.map { |g| 
      { group: g, channel_id: g.custom_field_value(reminder_field) } 
    } : []

    reminder_field.each { |info |
      config = {
        'channel' => info[:channel_id],
        'user_ids' => info[:group].users.pluck(:id),
        'team_name' => info[:group].name,
        'enabled_queries' => [:next_week_start_issues, :custom_overdue_new_issues, :delayed_issues],
        'query_type' => :custom
      }

      # pp config

      schedule_notification(config)
    }
  end

  # 나중에 공통 모듈로 뺴던가 하자
  def self.slack_message(text, channel_id = nil)
    token = Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_token']
    channel_id = channel_id || Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id']
    uri = URI('https://slack.com/api/chat.postMessage')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
  
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json; charset=utf-8'
    request['Authorization'] = "Bearer #{token}"

    body = if text.class == String then
            {
              channel: channel_id,
              text: text,
              blocks: [
                {
                  type: "section",
                  text: {
                    type: "mrkdwn",
                    text: text
                  }
                }
              ]
            }.to_json
          else
            # rich_text 블록을 blocks 배열로 감싸서 전달
            {
              channel: channel_id,
              text: '일감 리마인더',  # fallback text
              blocks: [text]  # text는 이미 rich_text 블록 형식
            }.to_json
          end

    pp body

    request.body = body
  
    response = http.request(request)

    pp response.code, response.body

    unless response.code == '200'
      Rails.logger.error "Slack message send error: #{response.code} #{response.body}"
    end
  end

  # Slack 메시지 전송
  def self.send_slack_message(msg)

    self.slack_message(msg)

    return
      
    uri = URI(Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_web_hook_url'])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = {
      channel: Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id'],
      username: USERNAME,
      blocks: [JSON.parse(msg)]
    }.to_json

    pp URI( Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_web_hook_url'] ), Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id'], USERNAME

    begin
      response = http.request(request)
      puts "Slack response: #{response.code}"
      puts response.body
    rescue => error
      warn "Slack 메시지 전송 실패: #{error}"
    end
  end

  def self.remind_yesterday()

    return holiday_today?

    return unless Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id']

    excluded_group_ids = TxBaseHelper.config_arr('e_group') || []
    user_ids = Group.all.select{ |group| !excluded_group_ids.include?(group.id) }.map { |g| g.users.select { |u| u.active? }.sort_by{ |u| u.name }.map { |u| u.id } }.flatten.uniq


    config = {
      'channel' => Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id'],
      'user_ids' => user_ids,
      'team_name' => '일간 리마인더',
      'enabled_queries' => [:yesterday_issues],
      'query_type' => :yesterday
    }

    schedule_notification( config )    
  end

  def self.remind_main()

    return holiday_today?

    return unless Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id']

    config = {
      'channel' => Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id'],
      'user_ids' => [],
      'team_name' => '전체',
      'enabled_queries' => [:main_upcoming_due_issues, :main_overdue_new_issues, :main_overdue_issues, :main_no_dates],
      #'enabled_queries' => [:main_upcoming_due_issues, :main_overdue_new_issues, :main_overdue_issues, :main_category_missing, :main_team_status, :main_no_dates],
      'query_type' => :main
    }

    schedule_notification( config )    
  end

=begin
    config = TEAM_CONFIGS[team_key]

    unless config
      warn "지원하지 않는 팀입니다: #{team_key}"
      warn "사용 가능한 팀: #{TEAM_CONFIGS.keys.join(', ')}"
      exit(1)
    end

    puts "#{config['team_name']} 설정으로 서버를 시작합니다..."

    schedule_notification(config)
=end
end

# 명령행 인자에서 팀 선택 (기본값: yesterday)
#if __FILE__ == $0
#  team_key = ARGV[0] || 'yesterday'
#  TxReminderRefactored.run(team_key)
#end
