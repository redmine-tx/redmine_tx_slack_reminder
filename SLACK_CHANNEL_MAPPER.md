# Slack 채널 매핑 가이드

`SlackChannelMapper` 클래스는 Slack 채널 이름과 채널 ID를 매핑하여 채널 이름으로 메시지를 전송할 수 있게 해주는 기능입니다.

## 주요 기능

- **자동 매핑**: Slack API를 통해 Public/Private 채널 정보를 가져와 이름과 ID 매핑
- **캐시 활용**: Rails 캐시를 사용하여 1일간 매핑 정보를 저장하여 API 호출 최소화
- **채널 메시지 전송**: 채널 이름으로 메시지 전송 가능
- **Private 채널 지원**: Bot이 초대된 Private 채널도 조회 가능

## Private 채널 조회 제한사항

⚠️ **중요**: Private 채널은 **Bot이 해당 채널에 초대되어 있어야만** 조회할 수 있습니다.

- Bot이 속하지 않은 Private 채널은 목록에 나타나지 않습니다.
- Private 채널을 사용하려면 먼저 Slack에서 Bot을 채널에 초대하세요.
- 채널에서 `/invite @bot이름` 명령으로 초대할 수 있습니다.

## 설정

### 1. Slack Bot Token Scopes

**필요한 권한:**
- `channels:read` - Public 채널 조회
- `groups:read` - Private 채널 조회 (선택사항)
- `chat:write` - 메시지 전송

### 2. Bot을 채널에 초대

Private 채널을 사용하려면:
1. Slack에서 해당 채널로 이동
2. `/invite @bot이름` 명령 실행
3. Bot이 채널에 참여하면 조회 가능

## 사용 방법

### 1. 채널 ID 조회

```ruby
# 채널 이름으로 ID 조회 (#있어도 됨)
channel_id = SlackChannelMapper.get_channel_id('general')
channel_id = SlackChannelMapper.get_channel_id('#general')  # 둘 다 가능

# 채널 상세 정보 조회
info = SlackChannelMapper.get_channel_details('general')
# => { id: "C1234567890", is_private: false, is_member: true, num_members: 150, ... }
```

### 2. 채널에 메시지 전송

```ruby
# 문자열 메시지 전송
SlackChannelMapper.send_message('general', '공지사항입니다.')

# 채널 ID로도 전송 가능
SlackChannelMapper.send_message('C1234567890', '메시지')

# Rich Text 블록으로 전송
message_block = {
  'type' => 'rich_text',
  'elements' => [
    {
      'type' => 'rich_text_section',
      'elements' => [
        {
          'type' => 'text',
          'text' => '중요 공지',
          'style' => { 'bold' => true }
        }
      ]
    }
  ]
}
SlackChannelMapper.send_message('general', message_block)
```

### 3. 채널 필터링

```ruby
# 모든 채널 조회
all_channels = SlackChannelMapper.all_mappings

# Public 채널만
public_channels = SlackChannelMapper.public_channels

# Private 채널만 (Bot이 초대된 것만)
private_channels = SlackChannelMapper.private_channels

# Bot이 참여한 채널만
joined_channels = SlackChannelMapper.joined_channels

# 채널 검색 (부분 일치)
dev_channels = SlackChannelMapper.search_channels('dev')
# => { "dev-team" => {...}, "dev-frontend" => {...}, ... }
```

### 4. 매핑 관리

```ruby
# 캐시 강제 갱신
SlackChannelMapper.refresh_mapping

# 채널 정보 조회
info = SlackChannelMapper.get_channel_info('C1234567890')
```

## Rake 태스크

### 채널 목록 조회

```bash
# 전체 채널 목록
rake slack_channel_mapper:list

# Bot이 참여한 채널만
rake slack_channel_mapper:joined

# Public 채널만
rake slack_channel_mapper:public

# Private 채널만
rake slack_channel_mapper:private
```

### 채널 검색 및 정보

```bash
# 채널 검색
rake slack_channel_mapper:search[dev]

# 채널 상세 정보
rake slack_channel_mapper:info[general]
```

### 테스트 및 관리

```bash
# 채널에 테스트 메시지 전송
rake slack_channel_mapper:test_message[general]

# 매핑 강제 갱신
rake slack_channel_mapper:refresh

# 캐시 정보
rake slack_channel_mapper:cache_info

# 캐시 삭제
rake slack_channel_mapper:clear_cache
```

## 출력 예시

### 채널 목록 조회

```bash
$ rake slack_channel_mapper:list

총 45개의 채널이 매핑되었습니다.

=== Public 채널 (38개) ===
채널명                          채널 ID         참여여부    멤버수
----------------------------------------------------------------------
#general                      C01234ABCDE     참여중      150
#random                       C01234FGHIJ     -           85
#dev-team                     C01234KLMNO     참여중      25
...

=== Private 채널 (7개) ===
채널명                          채널 ID         참여여부    멤버수
----------------------------------------------------------------------
#leadership                   C98765ABCDE     참여중      12
#confidential                 C98765FGHIJ     참여중      5
...

요약:
  전체 채널: 45개
  Public: 38개
  Private: 7개
  Bot 참여중: 15개
```

### 채널 상세 정보

```bash
$ rake slack_channel_mapper:info[general]

채널 정보:
  이름: #general
  ID: C01234ABCDE
  타입: Public
  Bot 참여: 예
  멤버수: 150
  주제: Company-wide announcements and work-based matters
  목적: This channel is for workspace-wide communication
```

## TxReminderRefactored 통합

기존 하드코딩된 채널 ID를 채널 이름으로 변경할 수 있습니다.

### 기존 방식 (하드코딩)

```ruby
TEAM_CONFIGS = {
  'dajin' => {
    'channel' => 'C06GW9XCTB4',  # 하드코딩된 ID
    # ...
  }
}
```

### 개선된 방식 (채널 이름 사용)

```ruby
TEAM_CONFIGS = {
  'dajin' => {
    'channel' => -> { SlackChannelMapper.get_channel_id('vision-team') },
    # 또는 직접 이름 사용
    'channel_name' => 'vision-team',
    # ...
  }
}

# 메시지 전송 시
config = TEAM_CONFIGS['dajin']
channel_id = config['channel'].is_a?(Proc) ? config['channel'].call : config['channel']

# 또는 더 간단하게
SlackChannelMapper.send_message('vision-team', message)
```

### 변환 도구

기존 설정을 분석하는 Rake 태스크:

```bash
rake slack_channel_mapper:convert_config
```

## 활용 예시

### 예시 1: 그룹별 채널에 알림

```ruby
# 그룹 커스텀 필드에서 채널 이름 가져오기
group = Group.find_by(lastname: '개발팀')
channel_field = GroupCustomField.find_by(name: 'slack_channel_name')
channel_name = group.custom_field_value(channel_field)  # 예: "dev-team"

if channel_name.present?
  message = "중요 공지: 이번 주 마감 일감을 확인하세요."
  SlackChannelMapper.send_message(channel_name, message)
end
```

### 예시 2: 프로젝트별 채널 자동 매핑

```ruby
# 프로젝트 식별자를 채널 이름으로 사용
project = Project.find_by(identifier: 'game-dev')
channel_name = "project-#{project.identifier}"  # "project-game-dev"

# 채널 존재 확인
if SlackChannelMapper.get_channel_id(channel_name)
  SlackChannelMapper.send_message(channel_name, "프로젝트 업데이트...")
else
  Rails.logger.warn "채널이 없습니다: #{channel_name}"
end
```

### 예시 3: 동적 채널 선택

```ruby
# 일감의 우선순위에 따라 다른 채널에 전송
issue = Issue.find(1234)

channel_name = case issue.priority_id
               when 5, 6  # Urgent, Immediate
                 'urgent-issues'
               when 4     # High
                 'high-priority'
               else
                 'general-issues'
               end

SlackChannelMapper.send_message(channel_name, "일감 ##{issue.id} 확인 필요")
```

### 예시 4: 여러 채널에 동시 전송

```ruby
# 특정 키워드가 있는 채널들에 공지
announcement_channels = SlackChannelMapper.search_channels('announce')

message = "전체 공지: 시스템 점검이 예정되어 있습니다."

announcement_channels.each do |channel_name, info|
  next unless info[:is_member]  # Bot이 참여한 채널만

  SlackChannelMapper.send_message(channel_name, message)
  sleep 0.5  # Rate limit 고려
end
```

### 예시 5: 채널 정보를 사용한 필터링

```ruby
# 멤버수가 많은 채널에만 전송 (대규모 공지)
large_channels = SlackChannelMapper.all_mappings.select do |name, info|
  info[:is_member] && info[:num_members].to_i > 50
end

message = "전사 공지사항"
large_channels.each do |channel_name, _|
  SlackChannelMapper.send_message(channel_name, message)
end
```

## 캐싱 메커니즘

- **캐시 키**: `slack_channel_mapping`
- **캐시 유효기간**: 1일 (86400초)
- **자동 갱신**: 캐시가 만료되면 자동으로 Slack API를 호출하여 갱신
- **페이지네이션**: 200개씩 자동으로 페이지네이션 처리
- **수동 갱신**: `refresh_mapping` 메서드로 즉시 갱신 가능

## Private 채널 작업 흐름

1. **채널 생성**: Slack에서 Private 채널 생성
2. **Bot 초대**: `/invite @bot이름` 명령으로 Bot 초대
3. **캐시 갱신**: `rake slack_channel_mapper:refresh`
4. **확인**: `rake slack_channel_mapper:private`로 채널 목록 확인
5. **사용**: 이제 채널 이름으로 메시지 전송 가능

## 트러블슈팅

### Private 채널이 목록에 없음

**원인**: Bot이 채널에 초대되지 않음

**해결**:
1. Slack에서 해당 Private 채널로 이동
2. `/invite @bot이름` 실행
3. `rake slack_channel_mapper:refresh` 실행

### 권한 부족 오류 (missing_scope)

**원인**: Bot Token에 필요한 권한이 없음

**해결**:
1. Slack App 설정 페이지로 이동
2. OAuth & Permissions > Scopes 확인
3. `groups:read` 권한 추가 (Private 채널용)
4. Bot 재설치 또는 재인증

### 메시지 전송 실패

**확인사항**:
- Bot이 채널에 참여했는지 확인: `rake slack_channel_mapper:info[채널명]`
- `is_member: true`인지 확인
- 테스트 메시지 전송: `rake slack_channel_mapper:test_message[채널명]`

## 성능 최적화

### 캐시 예열 (선택사항)

서버 시작 시 캐시를 미리 로드:

```ruby
# config/initializers/slack_channel_cache.rb
Rails.application.config.after_initialize do
  # 백그라운드에서 캐시 로드 (선택사항)
  Thread.new do
    sleep 5  # 서버 시작 후 5초 대기
    SlackChannelMapper.all_mappings
  end
end
```

### 자주 사용하는 채널 ID 저장

```ruby
# 자주 사용하는 채널은 상수로 저장
module SlackChannels
  GENERAL = SlackChannelMapper.get_channel_id('general')
  URGENT = SlackChannelMapper.get_channel_id('urgent')

  def self.reload!
    remove_const(:GENERAL) if const_defined?(:GENERAL)
    remove_const(:URGENT) if const_defined?(:URGENT)

    const_set(:GENERAL, SlackChannelMapper.get_channel_id('general'))
    const_set(:URGENT, SlackChannelMapper.get_channel_id('urgent'))
  end
end
```

## 보안 고려사항

1. **Private 채널**: Bot이 초대된 Private 채널 정보는 캐시에 저장됩니다.
2. **캐시 공유**: 멀티 서버 환경에서는 공유 캐시 스토어(Redis) 사용을 권장합니다.
3. **권한 관리**: Bot이 불필요한 채널에 초대되지 않도록 관리하세요.
