# Slack 사용자 매핑 가이드

`SlackUserMapper` 클래스는 Redmine 사용자와 Slack 사용자를 매핑하여 개인 DM을 전송할 수 있게 해주는 기능입니다.

## 주요 기능

- **자동 매핑**: Slack API를 통해 사용자 이메일 정보를 가져와 Redmine 로그인명과 자동 매핑
- **캐시 활용**: Rails 캐시를 사용하여 1일간 매핑 정보를 저장하여 API 호출 최소화
- **DM 전송**: Redmine 사용자에게 직접 Slack DM 전송 가능

## 설정

### 1. Slack Bot Token 설정

관리자 페이지 > 플러그인 > Redmine Tx Slack Reminder > 설정에서 Bot Token을 입력합니다.

**필요한 Bot Token Scopes:**
- `chat:write` - 메시지 전송
- `users:read` - 사용자 정보 조회
- `users:read.email` - 사용자 이메일 조회
- `im:write` - DM 채널 열기

### 2. 사용자 이메일 규칙

Slack 사용자의 이메일 주소에서 `@` 앞부분이 Redmine 로그인명과 일치해야 합니다.

**예시:**
- Slack 이메일: `john.doe@company.com`
- Redmine 로그인명: `john.doe`
- 매칭 성공 ✓

## 사용 방법

### 1. Slack 사용자 ID 조회

```ruby
# Redmine 로그인명으로 조회
slack_user_id = SlackUserMapper.get_slack_user_id('john.doe')

# Redmine User 객체로 조회
user = User.find_by(login: 'john.doe')
slack_user_id = SlackUserMapper.get_slack_user_id_by_user(user)
```

### 2. DM 전송

```ruby
# 문자열 메시지 전송
SlackUserMapper.send_dm('john.doe', '안녕하세요! 확인이 필요한 일감이 있습니다.')

# User 객체로 전송
user = User.find_by(login: 'john.doe')
SlackUserMapper.send_dm_to_user(user, '일감 #1234가 마감 예정입니다.')

# Rich Text 블록으로 전송
message_block = {
  'type' => 'rich_text',
  'elements' => [
    {
      'type' => 'rich_text_section',
      'elements' => [
        {
          'type' => 'link',
          'url' => 'https://redmine.example.com/issues/1234',
          'text' => '#1234 일감 확인 필요'
        }
      ]
    }
  ]
}
SlackUserMapper.send_dm('john.doe', message_block)
```

### 3. 매핑 정보 관리

```ruby
# 캐시된 매핑 정보 강제 갱신
SlackUserMapper.refresh_mapping

# 모든 매핑 정보 조회 (디버깅용)
all_mappings = SlackUserMapper.all_mappings
# => { "john.doe" => { id: "U1234567890", channel: "D9876543210" }, ... }
```

## 캐싱 메커니즘

- **캐시 키**: `slack_user_mapping`
- **캐시 유효기간**: 1일 (86400초)
- **자동 갱신**: 캐시가 만료되면 자동으로 Slack API를 호출하여 갱신
- **수동 갱신**: `refresh_mapping` 메서드로 즉시 갱신 가능

## 개발 모드 설정

개발 환경에서는 기본적으로 Slack 메시지 전송이 비활성화되어 있습니다.
개발 환경에서도 메시지를 전송하려면 플러그인 설정에서 "개발 모드에서 메시지 전송" 옵션을 체크하세요.

## 에러 처리

### DM 채널을 찾을 수 없는 경우

`channel_not_found` 오류가 발생하면 자동으로 DM 채널을 다시 열고 재시도합니다.

```ruby
# 자동으로 처리됨
SlackUserMapper.send_dm('john.doe', '메시지')
# 1. 채널이 없거나 무효한 경우
# 2. 자동으로 conversations.open API 호출
# 3. 새 채널 ID로 재시도
```

### 매핑되지 않은 사용자

Slack에 없는 사용자나 이메일이 설정되지 않은 사용자는 자동으로 건너뜁니다.

```ruby
result = SlackUserMapper.send_dm('nonexistent.user', '메시지')
# => false (로그에 오류 기록)
```

## redmine_slack 플러그인과의 차이점

| 항목 | redmine_slack | redmine_tx_slack_reminder |
|------|--------------|---------------------------|
| 캐싱 방식 | 클래스 변수 + 마지막 갱신 시간 | Rails.cache |
| 갱신 주기 | 1일 (수동 체크) | 1일 (자동 만료) |
| 메모리 사용 | 프로세스마다 별도 저장 | 공유 캐시 스토어 사용 |
| 확장성 | 단일 프로세스 | 멀티 프로세스/서버 지원 |

## 활용 예시

### 일감 담당자에게 알림

```ruby
issue = Issue.find(1234)
assignee = issue.assigned_to

if assignee && assignee.is_a?(User)
  message = "일감 ##{issue.id} 「#{issue.subject}」의 마감일이 내일입니다."
  SlackUserMapper.send_dm_to_user(assignee, message)
end
```

### 여러 사용자에게 일괄 전송

```ruby
users = User.active.where(login: ['john.doe', 'jane.smith', 'bob.wilson'])

users.each do |user|
  message = "#{user.name}님, 확인이 필요한 일감이 있습니다."
  SlackUserMapper.send_dm_to_user(user, message)
end
```

### 커스텀 쿼리로 스케줄 알림

```ruby
# TxReminderRefactored 모듈에서 사용 예시
def self.send_personal_reminders
  # 마감 임박 일감 조회
  issues = Issue.where('due_date = ?', Date.tomorrow)
                .where(status: IssueStatus.open)

  issues.group_by(&:assigned_to).each do |user, user_issues|
    next unless user.is_a?(User)

    # Rich text 블록 생성
    message_block = {
      'type' => 'rich_text',
      'elements' => user_issues.map { |issue|
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
      }
    }

    SlackUserMapper.send_dm_to_user(user, message_block)
  end
end
```

## 주의사항

1. **Bot Token 권한**: 위에서 언급한 모든 Scopes가 필요합니다.
2. **사용자 이메일**: Slack에서 사용자 이메일이 공개되어 있어야 합니다.
3. **로그인명 일치**: Redmine 로그인명과 Slack 이메일의 @ 앞부분이 정확히 일치해야 합니다.
4. **캐시 스토어**: 프로덕션 환경에서는 Redis 등의 공유 캐시 스토어 사용을 권장합니다.
