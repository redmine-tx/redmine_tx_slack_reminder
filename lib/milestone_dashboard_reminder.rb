# frozen_string_literal: true

require 'net/http'
require 'json'

class MilestoneDashboardReminder
  class << self
    # Send dashboard summary to Slack channel for a specific version
    def notify_channel(version_id)
      channel_id = Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_general_channel_id']
      return false unless channel_id

      send_dashboard(version_id, channel_id)
    end

    # Send dashboard summary as DM to a Redmine user
    def notify_dm(version_id, login)
      dm_channel_id = SlackUserMapper.open_dm_channel(login)
      return false unless dm_channel_id

      send_dashboard(version_id, dm_channel_id)
    end

    # Send dashboards for all active versions with default_version of each project
    def notify_channel_for_active_versions
      today = Date.current
      return if today.saturday? || today.sunday?
      return if TxReminderRefactored.holiday_today?

      version_ids = active_dashboard_version_ids
      return if version_ids.empty?

      SlackRateLimiter.run_in_background do
        version_ids.each do |vid|
          notify_channel(vid)
        rescue => e
          Rails.logger.error "MilestoneDashboardReminder error (version #{vid}): #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        end
      end
    end

    private

    def send_dashboard(version_id, channel_id)
      token = slack_token
      return false unless token

      User.current = User.find(1) # admin context for full visibility

      payload = RedmineTxMilestone::SlackDashboardNotifier.build_dashboard_payload(version_id)
      return false unless payload

      # Post text message
      post_message(token, channel_id, payload[:text])

      # Upload images
      payload[:images].each do |tmpfile|
        upload_file_to_slack(token, channel_id, tmpfile.path)
      end

      # Wait for Slack to finish rendering uploaded files before posting footer
      sleep(2) if payload[:images].any?

      # Post footer (dashboard link)
      post_message(token, channel_id, payload[:footer]) if payload[:footer].present?

      true
    rescue => e
      Rails.logger.error "MilestoneDashboardReminder send error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      false
    ensure
      payload[:images]&.each { |f| f.close rescue nil } if payload
    end

    def post_message(token, channel_id, text)
      uri = URI('https://slack.com/api/chat.postMessage')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json; charset=utf-8'
      request['Authorization'] = "Bearer #{token}"
      request.body = {
        channel: channel_id, text: text,
        blocks: [{ type: "section", text: { type: "mrkdwn", text: text } }]
      }.to_json

      response = SlackRateLimiter.send_with_throttle(http, request, channel_id)
      result = JSON.parse(response.body)
      Rails.logger.error "MilestoneDashboardReminder postMessage failed: #{result['error']}" unless result['ok']
      result['ok']
    end

    # Slack files.uploadV2 (3-step flow)
    def upload_file_to_slack(token, channel_id, file_path)
      http = Net::HTTP.new('slack.com', 443)
      http.use_ssl = true
      filename = File.basename(file_path)
      file_size = File.size(file_path)

      # Step 1: Get upload URL
      req1 = Net::HTTP::Post.new(URI('https://slack.com/api/files.getUploadURLExternal'))
      req1['Authorization'] = "Bearer #{token}"
      req1.set_form_data({ filename: filename, length: file_size })
      r1 = JSON.parse(http.request(req1).body)
      unless r1['ok']
        Rails.logger.error "MilestoneDashboardReminder getUploadURL failed: #{r1['error']}"
        return false
      end

      # Step 2: Upload file content
      upload_uri = URI(r1['upload_url'])
      upload_http = Net::HTTP.new(upload_uri.host, upload_uri.port)
      upload_http.use_ssl = true
      req2 = Net::HTTP::Post.new(upload_uri)
      req2['Content-Type'] = 'application/octet-stream'
      req2.body = File.binread(file_path)
      upload_http.request(req2)

      # Step 3: Complete upload and share to channel
      req3 = Net::HTTP::Post.new(URI('https://slack.com/api/files.completeUploadExternal'))
      req3['Authorization'] = "Bearer #{token}"
      req3['Content-Type'] = 'application/json; charset=utf-8'
      req3.body = { files: [{ id: r1['file_id'] }], channel_id: channel_id }.to_json
      r3 = JSON.parse(http.request(req3).body)
      unless r3['ok']
        Rails.logger.error "MilestoneDashboardReminder completeUpload failed: #{r3['error']}"
      end
      r3['ok']
    end

    def slack_token
      token = Setting.plugin_redmine_tx_slack_reminder['tx_slack_reminder_token']
      return nil if token.blank?
      token
    end

    # Find version ID to send dashboard for.
    # Uses the configured project's default_version.
    def active_dashboard_version_ids
      project_id = Setting.plugin_redmine_tx_slack_reminder['milestone_dashboard_project_id']
      return [] if project_id.blank?

      project = Project.find_by(id: project_id)
      return [] unless project&.active?

      version = project.default_version
      return [] unless version && version.status == 'open'

      [version.id]
    end
  end
end
