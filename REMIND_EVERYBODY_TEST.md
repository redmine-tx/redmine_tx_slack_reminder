# remind_everybody 테스트 가이드

개인별 DM 일감 알림(`remind_everybody`)을 rake task로 테스트하는 방법입니다.

## rake task 목록

| 명령 | 설명 |
|------|------|
| `rake remind_everybody:preview[login]` | Slack 전송 없이 콘솔에서 미리보기 |
| `rake remind_everybody:test[A,B]` | A의 일감 메시지를 B에게 DM 전송 |

## 1. 미리보기 (전송 없음)

Slack에 메시지를 보내지 않고, 해당 사용자에게 어떤 일감이 조회되는지 콘솔에서 확인합니다.

```bash
cd /var/www/redmine-dev
bundle exec rake remind_everybody:preview[hong.gildong]
```

출력 예시:

```
사용자: 홍길동 (hong.gildong)

=== 미리보기 ===

:date: 오늘 시작 일감 2건
  * #1234 로비 UI 개편 (진행)
  * #1235 설정 화면 리팩토링 (신규)

:date: 시작일 경과 미착수 일감 1건
  * #1237 보상 시스템 기획 (신규) -- 시작일 5일 경과

:date: 완료기한 초과 일감 1건
  * #1200 채팅 시스템 버그 수정 (진행) -- 1일 초과

=== JSON 블록 ===
{ ... }
```

## 2. 테스트 DM 전송

A 사용자의 일감을 조회해서, B 사용자에게 DM으로 보냅니다.
본인 계정으로 받아보고 싶을 때 사용합니다.

```bash
cd /var/www/redmine-dev
bundle exec rake remind_everybody:test[hong.gildong,kim.cheolsu]
```

- `hong.gildong` — 일감을 조회할 대상 (A)
- `kim.cheolsu` — DM을 받을 대상 (B)

A와 B를 같은 계정으로 지정하면 본인 일감을 본인이 받아볼 수 있습니다.

```bash
bundle exec rake remind_everybody:test[kim.cheolsu,kim.cheolsu]
```

## 3. 알림 카테고리

DM에 포함되는 일감은 4가지 카테고리입니다.

| 카테고리 | 조건 |
|----------|------|
| 오늘 시작 일감 | `start_date = 오늘`, 미종결 |
| 오늘 마감 일감 | `due_date = 오늘`, 미종결 |
| 시작일 경과 미착수 일감 | `start_date < 오늘`, 상태가 신규 |
| 완료기한 초과 일감 | `due_date < 오늘`, 진행중/신규 (구현끝/종결/폐기/보류 제외) |

## 4. 주의사항

- B 사용자는 Slack에 매핑되어 있어야 합니다 (Redmine 로그인명 = Slack 이메일 @ 앞부분).
- 매핑 상태는 `bundle exec rake slack_user_mapper:check_mapping`으로 확인할 수 있습니다.
- 개발 모드에서는 플러그인 설정의 `send_message_on_development_mode`가 `1`이어야 DM이 전송됩니다.
- 실제 스케줄은 매일 10:10 (cron `10 10 * * *`)에 자동 실행됩니다.
