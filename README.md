# notionScatch

Notion 데스크톱 앱에서 선택한 이미지 블록을 복사해 필기 편집창으로 열고, 확인 시 원래 자리로 교체를 시도하는 macOS helper입니다.

## 현재 동작

- Notion 앱에서 이미지 블록을 선택
- `Cmd+Shift+S`
- 편집창에서 필기
- `확인 후 Notion 교체`
- helper가 Notion으로 돌아가서 `Delete -> Paste`를 자동 시도

## 실행

```bash
cd /Users/kmg/Project/notionScatch
swift run
```

실행 후 메뉴 막대에 `NS` 아이콘이 생깁니다.

## 권한

처음 실행하면 macOS `손쉬운 사용` 권한이 필요합니다.

- 시스템 설정
- 개인정보 보호 및 보안
- 손쉬운 사용
- `notionScatch` 허용

## 제한

- Notion 앱의 공식 블록 선택 API가 없어서, 현재는 `선택된 이미지 블록`을 기준으로 UI 자동화를 합니다.
- Notion 포커스가 바뀌거나 이미지 선택이 풀리면 교체 대신 다른 위치에 붙여넣어질 수 있습니다.
- 현재 편집 도구는 자유 필기, 색상, 선 굵기, 되돌리기, 전체 지우기까지 구현했습니다.
