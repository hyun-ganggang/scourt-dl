# scourt-dl (대한민국 대법원 회생/파산 공고문 자동 다운로더)

대법원 법원공고 사이트에서 회생 및 파산 공고문(PDF)을 자동으로 조회하고 다운로드하는 PowerShell 스크립트.

## 주요 기능
- REST API를 활용한 빠르게 공고문 목록 조회
- Edge CDP(Chrome DevTools Protocol)를 통한 PDF 자동 저장
- 다운로드 성공/실패 현황 및 미완료 사건 목록 요약 출력

## 실행 방법
1. Microsoft Edge 브라우저 이용
2. 스크립트를 실행합니다:
   ```powershell
   .\download_court_notice.ps1
