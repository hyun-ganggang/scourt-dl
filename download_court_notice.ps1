# ============================================================
# Supreme Court 공고문 자동 다운로드 (PowerShell ISE용)
# Microsoft Edge 사용 버전
# ============================================================

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ============================================================
# 사용자 설정
# ============================================================
$Categories = @("일반회생", "법인회생", "법인파산")
$Regions = @("서울", "의정부", "인천", "수원", "춘천", "대전", "청주", "대구", "부산", "울산", "창원", "광주", "전주", "제주")
$TargetDate = "20260613"

# ============================================================
# 상수
# ============================================================
$SITE_URL = "https://ssgo.scourt.go.kr/ssgo/ssgo930/rhblBnkp.on"
$API_URL = "https://ssgo.scourt.go.kr/ssgo/ssgo930/selectRhblBnkpPbancLst.on"

$CATEGORY_CODE = @{
    "개인회생" = @{ TaskDvs = "1"; CsDvsCd = "253" }
    "개인파산" = @{ TaskDvs = "2"; CsDvsCd = "254" }
    "일반회생" = @{ TaskDvs = "3"; CsDvsCd = "291" }
    "법인회생" = @{ TaskDvs = "4"; CsDvsCd = "292" }
    "법인파산" = @{ TaskDvs = "5"; CsDvsCd = "293" }
    "국제도산" = @{ TaskDvs = "6"; CsDvsCd = "" }
}

$REGION_COURT = @{
    "서울" = "000221"; "의정부" = "000214"; "인천" = "000240"
    "수원" = "000249"; "춘천" = "000260"; "대전" = "000291"
    "청주" = "000270"; "대구" = "000321"; "부산" = "000443"
    "울산" = "000411"; "창원" = "000420"; "광주" = "000543"
    "전주" = "000520"; "제주" = "000530"
}

$BaseDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = (Get-Location).Path }

# ============================================================
# 표 출력용 디스플레이 너비 헬퍼 (한글=2, ASCII=1)
# ============================================================
function Get-DisplayWidth([string]$s) {
    $w = 0
    foreach ($c in $s.ToCharArray()) {
        $cp = [int][char]$c
        if (($cp -ge 0x1100 -and $cp -le 0x11FF) -or
            ($cp -ge 0xAC00 -and $cp -le 0xD7AF) -or
            ($cp -ge 0x2E80 -and $cp -le 0x9FFF) -or
            ($cp -ge 0xF900 -and $cp -le 0xFAFF)) {
            $w += 2
        } else {
            $w += 1
        }
    }
    return $w
}

function PadR([string]$s, [int]$w) {
    $pad = $w - (Get-DisplayWidth $s)
    if ($pad -lt 0) { $pad = 0 }
    return $s + (" " * $pad)
}

function PadL([string]$s, [int]$w) {
    $pad = $w - (Get-DisplayWidth $s)
    if ($pad -lt 0) { $pad = 0 }
    return (" " * $pad) + $s
}

# ============================================================
# 중복 파일명 처리: 같은 이름 존재 시 (1), (2) ... 추가
# ============================================================
function Get-SafeDestPath {
    param([string]$Dir, [string]$FileName)
    $dst = Join-Path $Dir $FileName
    if (-not (Test-Path $dst)) { return $dst }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName)
    $n = 1
    while (Test-Path (Join-Path $Dir "${base}($n)${ext}")) { $n++ }
    return Join-Path $Dir "${base}($n)${ext}"
}

# ============================================================
# Edge CDP 클래스
# ============================================================
class EdgeCDP {
    [System.Net.WebSockets.ClientWebSocket]$Socket
    [string]$WebSocketUrl
    [int]$MessageId
    [bool]$IsConnected
    
    EdgeCDP([string]$wsUrl) {
        $this.Socket = New-Object System.Net.WebSockets.ClientWebSocket
        $this.WebSocketUrl = $wsUrl
        $this.MessageId = 0
        $this.IsConnected = $false
    }
    
    [bool] Connect() {
        try {
            Write-Host "      [CDP] WebSocket 연결: $($this.WebSocketUrl)"
            $this.Socket.ConnectAsync($this.WebSocketUrl, [Threading.CancellationToken]::None).Wait(10000)
            $this.IsConnected = $true
            Write-Host "      [CDP] 연결 성공"
            return $true
        }
        catch {
            Write-Host "      [CDP] 연결 실패: $($_.Exception.InnerException.Message)"
            $this.IsConnected = $false
            return $false
        }
    }
    
    [string] Send([string]$method, [hashtable]$param) {
        if (-not $this.IsConnected) {
            Write-Host "      [CDP] 연결되지 않음 - Send 실패"
            return $null
        }
        
        $id = ++$this.MessageId
        $msg = @{
            id = $id
            method = $method
            params = $param
        } | ConvertTo-Json -Compress
        
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        
        try {
            $this.Socket.SendAsync(
                [ArraySegment[byte]]$bytes,
                [System.Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                [Threading.CancellationToken]::None
            ).Wait(10000)
            
            $buffer = [byte[]]::new(65536)
            $result = $this.Socket.ReceiveAsync(
                [ArraySegment[byte]]$buffer,
                [Threading.CancellationToken]::None
            )
            
            if ($result.Wait(10000) -and $result.Result.Count -gt 0) {
                $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $result.Result.Count)
                return $text
            }
        }
        catch {
            Write-Host "      [CDP] Send 오류: $($_.Exception.Message)"
        }
        return $null
    }
    
    # id 매칭으로 대용량 응답(PDF 등) 수신 - 중간 이벤트 메시지는 건너뜀
    [string] SendAndWait([string]$method, [hashtable]$param, [int]$timeoutMs) {
        if (-not $this.IsConnected) { return $null }

        $id = ++$this.MessageId
        $msg = @{
            id     = $id
            method = $method
            params = $param
        } | ConvertTo-Json -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)

        try {
            $this.Socket.SendAsync(
                [ArraySegment[byte]]$bytes,
                [System.Net.WebSockets.WebSocketMessageType]::Text,
                $true,
                [Threading.CancellationToken]::None
            ).Wait(10000)

            $deadline = [datetime]::UtcNow.AddMilliseconds($timeoutMs)
            while ([datetime]::UtcNow -lt $deadline) {
                $allBytes = New-Object System.Collections.Generic.List[byte]
                $buffer = [byte[]]::new(65536)

                do {
                    $remaining = [int]($deadline - [datetime]::UtcNow).TotalMilliseconds
                    if ($remaining -le 0) { return $null }
                    $task = $this.Socket.ReceiveAsync(
                        [ArraySegment[byte]]$buffer,
                        [Threading.CancellationToken]::None
                    )
                    if (-not $task.Wait($remaining)) { return $null }
                    if ($task.Result.Count -gt 0) {
                        $allBytes.AddRange($buffer[0..($task.Result.Count - 1)])
                    }
                } while (-not $task.Result.EndOfMessage)

                if ($allBytes.Count -gt 0) {
                    $text = [Text.Encoding]::UTF8.GetString($allBytes.ToArray())
                    if ($text -match ('"id"\s*:\s*' + $id + '[^0-9]')) { return $text }
                }
            }
        }
        catch {
            Write-Host "      [CDP] SendAndWait 오류: $($_.Exception.Message)"
        }
        return $null
    }

    [void] Close() {
        if ($this.Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $this.Socket.CloseAsync(
                [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                "",
                [Threading.CancellationToken]::None
            ).Wait(5000)
        }
        $this.IsConnected = $false
    }
}

# ============================================================
# Edge 시작 (Chrome 대신 Edge 사용)
# ============================================================
function Start-EdgeDebug {
    $edgePaths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    
    $edgePath = $null
    foreach ($path in $edgePaths) {
        if (Test-Path $path) {
            $edgePath = $path
            break
        }
    }
    
    if (-not $edgePath) {
        $edgePath = (Get-Command msedge.exe -ErrorAction SilentlyContinue).Source
    }
    
    if (-not $edgePath -or -not (Test-Path $edgePath)) {
        throw "Microsoft Edge를 찾을 수 없습니다"
    }
    
    Write-Host "    [Edge] 경로: $edgePath"
    
    $port = 9222
    $debugUrl = "http://127.0.0.1:$port"
    $userDir = "$env:TEMP\EdgeCDP_$PID"
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    
    $edgeArgs = @(
        "--remote-debugging-port=$port",
        "--user-data-dir=$userDir",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--edge-about-flags-enabled"
    )

    Write-Host "    [Edge] 프로세스 시작..."
    $edgeProc = Start-Process $edgePath -ArgumentList $edgeArgs -WindowStyle Normal -PassThru
    Start-Sleep -Seconds 3

    # 이미 다른 Edge 창/프로세스가 많이 떠있으면 디버그 포트 기동이 늦어질 수 있으므로
    # 충분히 길게(최대 약 60초) 재시도
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $targets = Invoke-RestMethod "$debugUrl/json" -TimeoutSec 2 -ErrorAction Stop
            if ($targets -and $targets.Count -gt 0) {
                Write-Host "    [Edge] 디버그 모드 준비됨 (포트 $port, ${i}초 대기)"
                return @{
                    DebugUrl = $debugUrl
                    Targets = $targets
                }
            }
        }
        catch {
            if ($i -eq 0) {
                Write-Host "    [Edge] 디버그 포트 연결 시도 실패(상세): $($_.Exception.Message)"
            }
            if ($i -gt 0 -and $i % 10 -eq 0) {
                Write-Host "    [Edge] 디버그 포트 대기 중... (${i}초)"
            }
            Start-Sleep -Seconds 1
        }
    }

    # 타임아웃 시 방금 띄운 Edge 프로세스를 정리하여 포트 점유 잔존(좀비 프로세스) 방지
    try {
        if ($edgeProc -and -not $edgeProc.HasExited) {
            $edgeProc.Kill()
        }
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$userDir*" } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    throw "Edge 디버그 포트 연결 실패"
}

function Connect-TargetCDP {
    param([array]$Targets)
    
    $target = $Targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
    if (-not $target) { $target = $Targets[0] }
    
    $wsUrl = $target.webSocketDebuggerUrl
    Write-Host "    [CDP] WebSocket URL: $wsUrl"
    
    $CDP = [EdgeCDP]::new($wsUrl)
    $success = $CDP.Connect()
    
    if (-not $success) {
        throw "WebSocket 연결 실패"
    }
    
    return $CDP
}

# ============================================================
# 세션 초기화
# ============================================================
function Initialize-Session {
    param([EdgeCDP]$CDP, [string]$DebugUrl)
    
    Write-Host "    [Edge] 사이트 접속..."
    $CDP.Send("Page.enable", @{})
    $CDP.Send("Network.enable", @{})
    
    $navResult = $CDP.Send("Page.navigate", @{ url = $SITE_URL })
    Start-Sleep -Seconds 5
    
    $uaResult = $CDP.Send("Runtime.evaluate", @{ expression = "navigator.userAgent" })
    $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
    
    if ($uaResult) {
        try {
            $parsed = $uaResult | ConvertFrom-Json
            if ($parsed.result.result.value) {
                $userAgent = $parsed.result.result.value
            }
        }
        catch { }
    }
    
    return $userAgent
}

# ============================================================
# API 목록 조회
# ============================================================
function Get-NoticeList {
    param(
        [string]$Category,
        [string]$CourtCode,
        [string]$TargetDate,
        [string]$UserAgent
    )
    
    $catInfo = $CATEGORY_CODE[$Category]
    
    $searchPart = @{
        taskDvs  = $catInfo.TaskDvs
        srchType = "pstgBgng"
        cortCd   = $CourtCode
        pstgDvs  = "999"
        csYr     = $TargetDate.Substring(2, 2)
        csDvsCd  = $catInfo.CsDvsCd
        csSrno   = ""
        csNo     = ""
        debtrNm  = ""
        jdbnCd   = ""
        bgnYmd   = $TargetDate
        endYmd   = $TargetDate
    }
    
    $pagePart = @{
        pageNo     = 1
        pageSize   = 500
        bfPageNo   = ""
        startRowNo = 1
        totalCnt   = 0
        totalYn    = "Y"
    }
    
    $body = @{
        dma_search   = $searchPart
        dma_pageInfo = $pagePart
    }
    
    $bodyJson = $body | ConvertTo-Json -Depth 5
    $payload = $bodyJson -replace '\s+', ''
    
    $headers = @{
        "Content-Type" = "application/json; charset=UTF-8"
        "User-Agent"   = $UserAgent
        "Referer"      = $SITE_URL
        "Accept"       = "application/json"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $API_URL -Method Post -Body $payload -ContentType "application/json; charset=UTF-8" -Headers $headers -TimeoutSec 30
        
        if ($response.data -and $response.data.dlt_pbancLst) {
            $items = $response.data.dlt_pbancLst
            return $items | Where-Object { $_.pbancBgngYmd -eq $TargetDate }
        }
    }
    catch {
        Write-Host "      [오류] API 요청 실패: $_"
    }
    return @()
}

# ============================================================
# PDF 다운로드
# ============================================================
function Save-PDF {
    param(
        [EdgeCDP]$CDP,
        [string]$EncParam,
        [string]$DownloadDir,
        [int]$WaitSec = 10
    )
    
    $paramJson = @{ encParam = $EncParam; pspTkn = "NA"; pspSid = "NA" } | ConvertTo-Json -Compress
    $paramData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($paramJson))
    
    $viewerUrl = "https://ecfs.scourt.go.kr/sgvo/websquare/websquare.html?w2xPath=/sgvo/ui/sgvo200/SGVO201M01.xml&paramData=$paramData"
    
    $CDP.Send("Page.navigate", @{ url = $viewerUrl })
    Start-Sleep -Seconds $WaitSec
    
    $CDP.Send("Runtime.evaluate", @{ expression = "document.querySelector('#mf_btn_save').click();" })
    Start-Sleep -Seconds 3
    
    return $true
}

# 팝업 창을 Page.printToPDF로 저장
function Save-PopupAsPDF {
    param(
        [string]$DebugUrl,
        [string]$SavePath,
        [string[]]$KnownTargetIds
    )

    Start-Sleep -Seconds 3

    try {
        $targets = Invoke-RestMethod "$DebugUrl/json" -TimeoutSec 5 -ErrorAction Stop
    }
    catch {
        Write-Host "      [팝업] CDP 목록 조회 실패"
        return $false
    }

    $popup = $targets | Where-Object {
        $_.type -eq "page" -and $_.id -notin $KnownTargetIds
    } | Select-Object -First 1

    if (-not $popup) {
        return $false
    }

    Write-Host "      [팝업] 새 창 감지됨 -> PDF 변환 중..."

    try {
        $popupCDP = [EdgeCDP]::new($popup.webSocketDebuggerUrl)
        if (-not $popupCDP.Connect()) {
            Write-Host "      [팝업] 연결 실패"
            return $false
        }

        Start-Sleep -Seconds 4

        $pdfJson = $popupCDP.SendAndWait("Page.printToPDF", @{
            printBackground = $true
            landscape       = $false
            paperWidth      = 8.27
            paperHeight     = 11.69
            marginTop       = 0.4
            marginBottom    = 0.4
            marginLeft      = 0.4
            marginRight     = 0.4
            transferMode    = "ReturnAsBase64"
        }, 60000)

        $popupCDP.Close()

        if (-not $pdfJson) {
            Write-Host "      [팝업] PDF 응답 없음"
            return $false
        }

        $parsed  = $pdfJson | ConvertFrom-Json
        $b64data = $parsed.result.data
        if (-not $b64data) {
            Write-Host "      [팝업] PDF 데이터 없음 (응답: $($pdfJson.Substring(0, [Math]::Min(200, $pdfJson.Length))))"
            return $false
        }
        $pdfBytes = [Convert]::FromBase64String($b64data)
        [IO.File]::WriteAllBytes($SavePath, $pdfBytes)
        Write-Host "      -> 팝업 PDF 저장 완료: $(Split-Path $SavePath -Leaf)"
        return $true
    }
    catch {
        Write-Host "      [팝업] PDF 저장 오류: $_"
        return $false
    }
    finally {
        # 사용한 팝업 탭은 정리 (다음 사건의 팝업 감지에 영향 없도록)
        try { Invoke-RestMethod "$DebugUrl/json/close/$($popup.id)" -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

function Wait-DownloadFinish {
    param([string]$DownloadDir, [int]$TimeoutSec = 30)

    $end = (Get-Date).AddSeconds($TimeoutSec)
    $lastSize = -1
    $stableCount = 0

    while ((Get-Date) -lt $end) {
        $crdownload = Get-ChildItem -Path $DownloadDir -Filter "*.crdownload" -ErrorAction SilentlyContinue
        if (-not $crdownload) {
            $pdfs = Get-ChildItem -Path $DownloadDir -Filter "*.pdf" -ErrorAction SilentlyContinue
            if ($pdfs) {
                $size = $pdfs[0].Length
                # 0바이트 상태로 생성된 직후를 완료로 오인하지 않도록
                # 파일 크기가 0보다 크고 연속 2회(1초) 동일하게 유지될 때만 완료로 판단
                if ($size -gt 0 -and $size -eq $lastSize) {
                    $stableCount++
                    if ($stableCount -ge 2) {
                        return $pdfs[0].Name
                    }
                } else {
                    $stableCount = 0
                }
                $lastSize = $size
            }
        }
        Start-Sleep -Milliseconds 500
    }

    # 타임아웃 시점에 파일이 있으면 (0바이트 포함) 일단 반환하여 호출부에서 판단/재시도하도록 함
    $pdfs = Get-ChildItem -Path $DownloadDir -Filter "*.pdf" -ErrorAction SilentlyContinue
    if ($pdfs) { return $pdfs[0].Name }
    return $null
}

# ============================================================
# 메인 실행
# ============================================================
Write-Host "============================================================"
Write-Host " Supreme Court 공고문 자동 다운로드"
Write-Host " (Microsoft Edge 사용)"
Write-Host "============================================================"
Write-Host "대상 날짜: $TargetDate"
Write-Host "카테고리: $($Categories -join ', ')"
Write-Host "지역: $($Regions -join ', ')"
Write-Host ""

Write-Host "[Edge] 시작 중..."
try {
    $edgeInfo = Start-EdgeDebug
    $debugUrl = $edgeInfo.DebugUrl
    $targets = $edgeInfo.Targets
}
catch {
    Write-Host "[오류] Edge 시작 실패: $_"
    exit 1
}

Write-Host "[CDP] 연결 중..."
try {
    $CDP = Connect-TargetCDP -Targets $targets
}
catch {
    Write-Host "[오류] CDP 연결 실패: $_"
    exit 1
}

Write-Host "[세션] 초기화 중..."
$userAgent = Initialize-Session -CDP $CDP -DebugUrl $debugUrl
Write-Host "    User-Agent: $userAgent"

$results = @{}
$totalFound = 0
$totalDownloaded = 0
$incompleteCases = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($cat in $Categories) {
    $results[$cat] = @{}
    $catDir = Join-Path $BaseDir "${cat}_$TargetDate"
    New-Item -ItemType Directory -Path $catDir -Force | Out-Null
    
    foreach ($region in $Regions) {
        $courtCode = $REGION_COURT[$region]
        if (-not $courtCode) {
            Write-Host "`n[$cat - $region] 법원 코드 없음, 건너뜀"
            $results[$cat][$region] = @{ Found = 0; Downloaded = 0 }
            continue
        }
        
        Write-Host "`n[$cat - $region] 목록 조회 중..."
        $items = Get-NoticeList -Category $cat -CourtCode $courtCode -TargetDate $TargetDate -UserAgent $userAgent
        $found = @($items).Count
        $totalFound += $found
        Write-Host "  $found 건 발견"
        
        $downloaded = 0
        if ($found -gt 0) {
            $tmpDir = Join-Path $BaseDir "tmp_$PID"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            
            foreach ($item in $items) {
                $caseNo = $item.csNoNm
                $title  = $item.pbancTitlNm
                $enc    = $item.encParam
                Write-Host "    [$caseNo] $title"

                # encParam이 없으면 자동 뷰어 접근 자체가 불가능한 케이스 -> 수동 확인 대상으로 기록
                if (-not $enc) {
                    Write-Host "      [미완료] encParam 없음 - 자동 처리 불가, 수동 확인 필요"
                    $incompleteCases.Add([PSCustomObject]@{
                        Region   = $region
                        Category = $cat
                        CaseNo   = $caseNo
                        Title    = $title
                        Reason   = "encParam 없음 (자동 뷰어 접근 불가)"
                    })
                    Start-Sleep -Seconds 1
                    continue
                }

                $safeCaseNo = ($caseNo -replace '[\\/:*?"<>|]', '_').Trim()
                $success = $false
                $failReason = "알수없음"

                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    # 이전 시도의 잔여 파일 제거 (충돌/오인 방지)
                    Get-ChildItem -Path $tmpDir -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

                    # 현재 열린 CDP 타겟 목록 스냅샷 (팝업 감지용)
                    $beforeIds = @()
                    try {
                        $beforeIds = @((Invoke-RestMethod "$debugUrl/json" -TimeoutSec 5 -ErrorAction Stop) | Select-Object -ExpandProperty id)
                    } catch {}

                    $CDP.Send("Page.setDownloadBehavior", @{ behavior = "allow"; downloadPath = $tmpDir })

                    $waitSec = if ($attempt -eq 1) { 10 } else { 16 }
                    Save-PDF -CDP $CDP -EncParam $enc -DownloadDir $tmpDir -WaitSec $waitSec
                    $fileName = Wait-DownloadFinish -DownloadDir $tmpDir -TimeoutSec 30

                    if ($fileName) {
                        $src = Join-Path $tmpDir $fileName
                        $srcSize = (Get-Item $src).Length

                        if ($srcSize -gt 0) {
                            $dst = Get-SafeDestPath -Dir $catDir -FileName $fileName
                            Move-Item -Path $src -Destination $dst -Force
                            Write-Host "      -> 저장 완료: $(Split-Path $dst -Leaf) ($srcSize bytes)"
                            $success = $true
                            break
                        } else {
                            Remove-Item -Path $src -Force -ErrorAction SilentlyContinue
                            $failReason = "0바이트 다운로드"
                            Write-Host "      [경고] 0바이트 다운로드 감지 (시도 $attempt/2)"
                        }
                    } else {
                        # 다운로드 없음 -> 팝업 창으로 열렸는지 확인 후 PDF 변환 시도
                        $popupDst = Get-SafeDestPath -Dir $catDir -FileName "${safeCaseNo}_popup.pdf"
                        $saved = Save-PopupAsPDF -DebugUrl $debugUrl -SavePath $popupDst -KnownTargetIds $beforeIds
                        if ($saved) {
                            $popupSize = (Get-Item $popupDst).Length
                            if ($popupSize -gt 0) {
                                Write-Host "      -> 팝업 PDF 저장 완료: $(Split-Path $popupDst -Leaf) ($popupSize bytes)"
                                $success = $true
                                break
                            } else {
                                Remove-Item -Path $popupDst -Force -ErrorAction SilentlyContinue
                                $failReason = "팝업 PDF 0바이트"
                            }
                        } else {
                            $failReason = "다운로드/팝업 모두 실패 (타임아웃)"
                        }
                    }

                    if ($attempt -lt 2) {
                        Write-Host "      [재시도] $attempt/2 실패 -> 재시도"
                        Start-Sleep -Seconds 2
                    }
                }

                if ($success) {
                    $downloaded++
                } else {
                    Write-Host "      [미완료] $region $cat $caseNo - $failReason"
                    $incompleteCases.Add([PSCustomObject]@{
                        Region   = $region
                        Category = $cat
                        CaseNo   = $caseNo
                        Title    = $title
                        Reason   = $failReason
                    })
                }

                Start-Sleep -Seconds 1
            }
            
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        $totalDownloaded += $downloaded
        $results[$cat][$region] = @{ Found = $found; Downloaded = $downloaded }
    }
}

# ============================================================
# 결과 요약
# ============================================================
Write-Host "`n============================================================"
Write-Host " 결과 요약 (대상 날짜: $TargetDate)"
Write-Host "============================================================"

$CAT_W = 10
$VAL_W = 8

$header = PadR "카테고리" $CAT_W
foreach ($r in $Regions) { $header += " | " + (PadL $r $VAL_W) }
$header += " | " + (PadL "합계" $VAL_W)
Write-Host $header

$sepLen = $CAT_W + ($Regions.Count + 1) * ($VAL_W + 3)
Write-Host ("-" * $sepLen)

foreach ($cat in $Categories) {
    $row     = PadR $cat $CAT_W
    $catTotal = 0
    foreach ($r in $Regions) {
        $d   = $results[$cat][$r]
        $val = "{0}/{1}" -f $d.Downloaded, $d.Found
        $row += " | " + (PadL $val $VAL_W)
        $catTotal += $d.Downloaded
    }
    $row += " | " + (PadL "$catTotal" $VAL_W)
    Write-Host $row
}

Write-Host ("-" * $sepLen)

$totalRow = PadR "합계" $CAT_W
$grandTotal = 0
foreach ($r in $Regions) {
    $rDl = 0; $rFd = 0
    foreach ($cat in $Categories) { $rDl += $results[$cat][$r].Downloaded; $rFd += $results[$cat][$r].Found }
    $val = "{0}/{1}" -f $rDl, $rFd
    $totalRow += " | " + (PadL $val $VAL_W)
    $grandTotal += $rDl
}
$totalRow += " | " + (PadL "$grandTotal" $VAL_W)
Write-Host $totalRow

Write-Host "`n총 발견: ${totalFound}건, 총 다운로드: ${totalDownloaded}건"
Write-Host "`n저장 위치:"
foreach ($cat in $Categories) {
    $d = Join-Path $BaseDir "${cat}_$TargetDate"
    if (Test-Path $d) {
        $files = @(Get-ChildItem -Path $d -Filter "*.pdf" -ErrorAction SilentlyContinue)
        Write-Host "  $cat : $($files.Count)건 -> $d"
    }
}

# 미완료 사건 목록 별도 출력 (encParam 없음 / 0바이트 / 타임아웃 등)
if ($incompleteCases.Count -gt 0) {
    Write-Host "`n============================================================"
    Write-Host " 미완료 사건 목록 (자동 다운로드 실패 - 수동 확인 필요)"
    Write-Host " 총 $($incompleteCases.Count)건"
    Write-Host "============================================================"

    $incompleteCases | Group-Object Region, Category | ForEach-Object {
        $parts = $_.Name -split ', '
        Write-Host "`n  [$($parts[0]) - $($parts[1])] $($_.Count)건"
        $_.Group | ForEach-Object {
            Write-Host "    - $($_.CaseNo) : $($_.Title)  [사유: $($_.Reason)]"
        }
    }
    Write-Host ""
}

try {
    $CDP.Close()
} catch {
    Write-Host "`n[참고] CDP 연결 종료 중 경고(무시 가능): $($_.Exception.Message)"
}
Write-Host "`n작업 완료. Edge 창을 닫으세요."
