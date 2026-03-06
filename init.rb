Redmine::Plugin.register :redmine_tx_slack_reminder do
  name 'Redmine Tx Slack Reminder plugin'
  author 'KiHyun Kang'
  description '주의가 필요한 일감들을 사용자에게 슬랙으로 알려주는 플러그인입니다.'
  version '0.0.1'
  url 'http://example.com/path/to/plugin'
  author_url 'http://example.com/about'

  requires_redmine_plugin :redmine_tx_scheduler, :version_or_higher => '0.0.1'
  requires_redmine_plugin :redmine_tx_more_calendar, :version_or_higher => '0.0.1'
  
  settings :default => {
    'tx_slack_reminder_general_channel_id' => nil,
    'tx_slack_reminder_token' => nil,
    'send_message_on_development_mode' => '0',
    'dm_target_group_ids' => []
  }, :partial => 'settings/tx_slack_reminder'
end

Rails.application.config.after_initialize do
  require_dependency File.expand_path('../lib/slack_rate_limiter.rb', __FILE__)
  require_dependency File.expand_path('../lib/slack_user_mapper.rb', __FILE__)
  require_dependency File.expand_path('../lib/slack_channel_mapper.rb', __FILE__)
  require_dependency File.expand_path('../lib/tx_reminder_refactored.rb', __FILE__)
  require_dependency File.expand_path('../lib/milestone_dashboard_reminder.rb', __FILE__)

    RedmineScheduler.register_task(
      name: '마일스톤 대시보드 알림',
      description: '마일스톤 대시보드 요약을 슬랙 채널에 전송',
      cron: '40 9 * * *'  # 매일 9시 40분
    ) do
      MilestoneDashboardReminder.notify_channel_for_active_versions
      Rails.logger.info "마일스톤 대시보드 알림 executed at #{Time.current}"
    end

    RedmineScheduler.register_task(
      name: '그룹별 레드마인 알림',
      description: '그룹별 레드마인 알림',
      cron: '50 9 * * *'  # 매일 9시 50분
    ) do
      TxReminderRefactored.remind_group()
      Rails.logger.info "그룹별 레드마인 알림 executed at #{Time.current}"
    end

=begin
    RedmineScheduler.register_task(
      name: 'yesterday 레드마인 알림',
      description: 'yesterday 레드마인 알림',
      cron: '55 9 * * *'  # 매일 9시 55분
    ) do
      TxReminderRefactored.remind_yesterday()
      Rails.logger.info "yesterday 레드마인 알림 executed at #{Time.current}"
    end
=end

    RedmineScheduler.register_task(
      name: 'main 레드마인 알림',
      description: 'main 레드마인 알림',
      cron: '00 10 * * *'  # 매일 10시 00분
    ) do
      TxReminderRefactored.remind_main()
      Rails.logger.info "main 레드마인 알림 executed at #{Time.current}"
    end

    RedmineScheduler.register_task(
      name: '개인별 DM 레드마인 알림',
      description: '개인별 DM 레드마인 알림',
      cron: '10 10 * * *'  # 매일 10시 10분
    ) do
      TxReminderRefactored.remind_everybody()
      Rails.logger.info "개인별 DM 레드마인 알림 executed at #{Time.current}"
    end

end
