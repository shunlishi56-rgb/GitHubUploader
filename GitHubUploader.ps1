# ============================================================
# GitHub 上传工具 v1.1（多账号版）
# 作者：星辰超级智能体（TeleAgent）
# 日期：2026-09-27
# ============================================================
# 功能：
#   1. 覆盖上传：用新压缩包整体替换仓库内容
#   2. 增量推送：直接推送本地仓库文件的修改
#   3. 自动检测 GitHub 连通性，不通时自动切换可用 IP
#   4. 支持打版本标签（v1.0 / v2.0 ...）
#   5. 实时日志输出
#   6. 多账号支持：可切换任意 GitHub 账号，凭据互不冲突
#      - 仓库框填「仓库名」→ 推到你账号下的仓库
#      - 仓库框填「所有者/仓库名」→ 以当前账号身份推别人的协作仓库
#   7. 配置记忆：记住上次用的账号和仓库，下次打开自动填好
# 使用：双击「GitHub上传工具.bat」运行
# 变更记录：
#   v1.1 新增多账号支持、协作仓库支持、配置记忆
#   v1.0 初版：覆盖上传 / 增量推送 / 网络自愈 / 版本标签
# ============================================================

# ---- 自提升管理员权限（需要改 hosts）----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ---- 全局错误捕获（出错时写日志文件，不闪退）----
trap {
    $errInfo = "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n错误: $($_.Exception.Message)`r`n位置: $($_.ScriptStackTrace)`r`n---"
    try { $errInfo | Out-File -FilePath (Join-Path $PSScriptRoot 'GitHub上传工具-错误.log') -Encoding utf8 -Append } catch { }
    Write-Host "发生错误，请查看「GitHub上传工具-错误.log」"
    Start-Sleep -Seconds 5
    exit 1
}

# ---- 加载 Windows Forms ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- 全局配置 ----
$script:LocalBase = 'D:\'                # 本地仓库存放目录
$script:GitHubIPs = @('140.82.113.3','140.82.114.3','140.82.116.3','140.82.121.3','140.82.112.3')
$script:HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$script:ConfigFile = Join-Path $PSScriptRoot 'GitHub上传工具配置.json'

# ---- 配置读写（记住账号和仓库历史）----
function Read-Config {
    $default = @{ lastAccount = 'shunlishi56-rgb'; accounts = @('shunlishi56-rgb'); lastRepo = 'h5-kefu' }
    if (-not (Test-Path $script:ConfigFile)) { return $default }
    try {
        $raw = Get-Content $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfg = @{}
        $cfg.lastAccount = if ($raw.lastAccount) { $raw.lastAccount } else { $default.lastAccount }
        $cfg.accounts = if ($raw.accounts) { @($raw.accounts) } else { $default.accounts }
        $cfg.lastRepo = if ($raw.lastRepo) { $raw.lastRepo } else { $default.lastRepo }
        return $cfg
    } catch {
        return $default
    }
}
function Save-Config {
    param([string]$Account, [string]$Repo)
    try {
        $cfg = Read-Config
        $accounts = @($cfg.accounts)
        if ($accounts -notcontains $Account) { $accounts += $Account }
        $obj = @{ lastAccount = $Account; accounts = $accounts; lastRepo = $Repo }
        $obj | ConvertTo-Json | Out-File $script:ConfigFile -Encoding utf8
    } catch { }
}

# ---- 日志函数 ----
function Write-Log {
    param([string]$Message)
    $script:txtLog.AppendText("$Message`r`n")
    $script:txtLog.SelectionStart = $script:txtLog.Text.Length
    $script:txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ---- 测试 IP 端口连通性 ----
function Test-Port {
    param([string]$IP, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $async = $tcp.BeginConnect($IP, $Port, $null, $null)
    $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
    $connected = $ok -and $tcp.Connected
    $tcp.Close()
    return $connected
}

# ---- 修复 GitHub 网络（自动切换 hosts，支持强制换节点）----
function Repair-GitHubNetwork {
    param([switch]$ForceSwitch)
    Write-Log "[网络] 检测 GitHub 连通性..."
    # 读取当前 hosts 指向
    $currentIp = $null
    $hostsContent = Get-Content $script:HostsFile -ErrorAction SilentlyContinue
    $githubLine = $hostsContent | Where-Object { $_ -match 'github\.com' } | Select-Object -First 1
    if ($githubLine -match '^\s*(\d+\.\d+\.\d+\.\d+)') { $currentIp = $Matches[1] }
    if ($ForceSwitch -and $currentIp) { Write-Log "[网络] 当前节点 $currentIp 异常，尝试切换其他节点..." }
    # 依次测试各节点，收集可用 IP
    $reachable = @()
    foreach ($ip in $script:GitHubIPs) {
        Write-Log "[网络] 测试 $ip ..."
        if (Test-Port -IP $ip) { $reachable += $ip }
    }
    if ($reachable.Count -eq 0) {
        Write-Log "[网络] 所有节点均不通，请检查网络或稍后重试"
        return $false
    }
    # 选择目标节点
    if (-not $ForceSwitch) {
        if ($currentIp -and ($reachable -contains $currentIp)) {
            Write-Log "[网络] hosts 已指向可用 IP $currentIp，无需修改"
            return $true
        }
    }
    $target = $reachable | Where-Object { $_ -ne $currentIp } | Select-Object -First 1
    if (-not $target) { $target = $reachable[0] }
    if ($target -eq $currentIp) {
        Write-Log "[网络] 当前节点 $currentIp 为唯一可用节点，保持不变"
        return $true
    }
    # 切换 hosts
    Write-Log "[网络] 切换 hosts 指向 $target ..."
    try {
        $newContent = $hostsContent | Where-Object { $_ -notmatch 'github\.com' }
        $newContent += "$target github.com"
        $newContent += "# GitHub上传工具管理"
        Set-Content -Path $script:HostsFile -Value $newContent -Force
        try { Clear-DnsClientCache -ErrorAction Stop } catch { & ipconfig.exe /flushdns | Out-Null }
        Write-Log "[网络] 已切换到 $target（DNS 缓存已刷新）"
        return $true
    } catch {
        Write-Log "[网络] hosts 修改失败: $($_.Exception.Message)"
        return $false
    }
}

# ---- 带重试的 git 操作 ----
function Invoke-Git {
    param([string[]]$Arguments, [string]$WorkingDir, [int]$MaxRetry = 3)
    for ($i = 1; $i -le $MaxRetry; $i++) {
        if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
            $output = & git @Arguments 2>&1
        } else {
            $output = & git -C $WorkingDir @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { return @{ Success = $true; Output = $output } }
        Write-Log "[git] 第 $i 次失败: $($output | Out-String)"
        if ($output -match 'Connection was reset|Could not connect|timed out|Failed to connect') {
            Write-Log "[git] 网络问题，尝试修复..."
            if (-not (Repair-GitHubNetwork -ForceSwitch)) { return @{ Success = $false; Output = $output } }
        } else {
            if ($i -lt $MaxRetry) { Start-Sleep -Seconds 2 }
        }
    }
    return @{ Success = $false; Output = $output }
}

# ---- 获取本地仓库列表 ----
function Get-LocalRepos {
    $repos = @()
    Get-ChildItem $script:LocalBase -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-Path "$($_.FullName)\.git") { $repos += $_.Name }
    }
    # 始终包含用户已知仓库
    foreach ($r in @('h5-kefu','nav-system')) {
        if ($repos -notcontains $r) { $repos += $r }
    }
    return $repos
}

# ---- 解析仓库输入（支持「仓库名」或「所有者/仓库名」）----
function Resolve-Repo {
    param([string]$RepoName, [string]$Account)
    $name = $RepoName.Trim('/')
    if ($name -match '^(.+)/(.+)$') {
        return @{ Owner = $Matches[1]; Repo = $Matches[2] }
    }
    return @{ Owner = $Account; Repo = $name }
}

# ---- 确保仓库本地可用（没有就 clone；账号变化时自动切换 remote）----
function Ensure-Repo {
    param([string]$RepoName, [string]$Account)
    $info = Resolve-Repo -RepoName $RepoName -Account $Account
    $remoteUrl = "https://$Account@github.com/$($info.Owner)/$($info.Repo).git"
    $repoPath = Join-Path $script:LocalBase $info.Repo
    if (Test-Path "$repoPath\.git") {
        Write-Log "[仓库] $($info.Repo) 已存在本地: $repoPath"
        # 确保以当前账号身份操作（切换账号时自动换 remote）
        $remoteResult = Invoke-Git -Arguments @('remote','set-url','origin',$remoteUrl) -WorkingDir $repoPath -MaxRetry 1
        if ($remoteResult.Success) { Write-Log "[仓库] 已以账号 [$Account] 身份连接" }
        # 拉取远程最新
        Write-Log "[仓库] 拉取远程最新..."
        $result = Invoke-Git -Arguments @('pull','origin','main') -WorkingDir $repoPath
        if ($result.Success) { Write-Log "[仓库] 拉取成功" }
        else { Write-Log "[警告] 拉取失败，可能远程无更新或有冲突，继续操作" }
        return $repoPath
    }
    Write-Log "[仓库] 本地不存在，开始克隆 $($info.Owner)/$($info.Repo) ..."
    $result = Invoke-Git -Arguments @('clone',$remoteUrl,$repoPath)
    if (-not $result.Success) {
        Write-Log "[错误] 克隆失败: $($result.Output | Out-String)"
        return $null
    }
    Write-Log "[仓库] 克隆成功: $repoPath"
    return $repoPath
}

# ---- 覆盖上传：用压缩包替换仓库全部内容 ----
function Start-OverwriteUpload {
    param([string]$ZipPath, [string]$RepoName, [string]$Account, [string]$Version, [string]$Desc)

    # 验证文件存在
    if (-not (Test-Path $ZipPath)) { Write-Log "[错误] 压缩包不存在: $ZipPath"; return $false }
    if ([System.IO.Path]::GetExtension($ZipPath) -ne '.zip') { Write-Log "[错误] 只支持 .zip 格式"; return $false }

    # 确保仓库可用
    $repoPath = Ensure-Repo -RepoName $RepoName -Account $Account
    if (-not $repoPath) { return $false }

    # 打标签保留旧版（用简单字符串计算，避免 -replace 脚本块在 PS 5.1 的兼容问题）
    $oldVersion = $null
    if ($Version -match '^v(\d+)\.(\d+)$') {
        $maj = [int]$Matches[1]; $min = [int]$Matches[2]
        if ($min -gt 0) { $oldVersion = "v$maj.$($min - 1)" } else { $oldVersion = "v$($maj - 1).9" }
    }
    if ($oldVersion) {
        Write-Log "[标签] 给当前旧版打标签 $oldVersion ..."
        $tagResult = Invoke-Git -Arguments @('tag',$oldVersion) -WorkingDir $repoPath -MaxRetry 1
        if ($tagResult.Success) {
            Invoke-Git -Arguments @('push','origin',$oldVersion) -WorkingDir $repoPath | Out-Null
            Write-Log "[标签] 旧版已标记为 $oldVersion"
        } else {
            Write-Log "[标签] $oldVersion 已存在或跳过"
        }
    }

    # 清空仓库（保留 .git）
    Write-Log "[覆盖] 清空旧文件..."
    Get-ChildItem -Force $repoPath | Where-Object { $_.Name -ne '.git' } | Remove-Item -Recurse -Force

    # 解压
    Write-Log "[覆盖] 解压新压缩包..."
    $tempDir = Join-Path $env:TEMP "gh-upload-$(Get-Date -Format 'yyyyMMddHHmmss')"
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tempDir)
    } catch {
        Write-Log "[错误] 解压失败: $($_.Exception.Message)"
        return $false
    }

    # 处理嵌套文件夹（压缩包只有一层目录时把内容挪上来）
    $tempItems = Get-ChildItem -Force $tempDir
    if ($tempItems.Count -eq 1 -and $tempItems[0].PSIsContainer) {
        $innerDir = $tempItems[0].FullName
        robocopy $innerDir $repoPath /E /IS /NFL /NDL /NJH /NJS | Out-Null
    } else {
        robocopy $tempDir $repoPath /E /IS /NFL /NDL /NJH /NJS | Out-Null
    }
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "[覆盖] 新文件已就位"

    # 提交推送（Version 已含 v 前缀，不再额外拼 v）
    return Start-CommitAndPush -RepoPath $repoPath -Message "$Version $Desc" -Tag $Version -Owner $Account
}

# ---- 增量推送：直接提交本地修改 ----
function Start-IncrementalPush {
    param([string]$RepoName, [string]$Account, [string]$Version, [string]$Desc)

    $info = Resolve-Repo -RepoName $RepoName -Account $Account
    $repoPath = Join-Path $script:LocalBase $info.Repo
    if (-not (Test-Path "$repoPath\.git")) {
        Write-Log "[错误] 仓库 $($info.Repo) 不在本地，请先用覆盖上传克隆一次"
        return $false
    }

    # 确保以当前账号身份操作
    $remoteUrl = "https://$Account@github.com/$($info.Owner)/$($info.Repo).git"
    Invoke-Git -Arguments @('remote','set-url','origin',$remoteUrl) -WorkingDir $repoPath -MaxRetry 1 | Out-Null
    Write-Log "[仓库] 已以账号 [$Account] 身份连接 $($info.Owner)/$($info.Repo)"

    # 检查是否有改动
    $status = & git -C $repoPath status --porcelain 2>&1
    if (-not $status) {
        Write-Log "[提示] 没有检测到任何改动，无需推送"
        return $true
    }
    $changeCount = ($status | Measure-Object).Count
    Write-Log "[增量] 检测到 $changeCount 个文件变动"

    return Start-CommitAndPush -RepoPath $repoPath -Message "$Version $Desc" -Tag $Version -Owner $Account
}

# ---- 提交并推送 ----
function Start-CommitAndPush {
    param([string]$RepoPath, [string]$Message, [string]$Tag, [string]$Owner)

    Write-Log "[提交] 暂存所有变更..."
    $addResult = Invoke-Git -Arguments @('add','-A') -WorkingDir $RepoPath -MaxRetry 1
    if (-not $addResult.Success) { Write-Log "[错误] add 失败"; return $false }

    Write-Log "[提交] 提交: $Message"
    $commitResult = Invoke-Git -Arguments @('commit','-m',$Message) -WorkingDir $RepoPath -MaxRetry 1
    if (-not $commitResult.Success) {
        $commitOut = $commitResult.Output | Out-String
        # nothing to commit 不算错误，继续推送（本地可能有未推送的提交）
        if ($commitOut -match 'nothing to commit') {
            Write-Log "[提交] 无新改动需要提交，继续推送已有的本地提交"
        } else {
            Write-Log "[警告] commit 输出: $commitOut"
            return $false
        }
    }

    if ($Tag -match '^v\d+\.\d+$') {
        Write-Log "[标签] 打版本标签 $Tag ..."
        Invoke-Git -Arguments @('tag',$Tag) -WorkingDir $RepoPath -MaxRetry 1 | Out-Null
    }

    Write-Log "[推送] 推送到 GitHub ..."
    $pushResult = Invoke-Git -Arguments @('push','origin','main') -WorkingDir $RepoPath
    if (-not $pushResult.Success) {
        Write-Log "[错误] 推送失败: $($pushResult.Output | Out-String)"
        return $false
    }
    Write-Log "[推送] main 分支推送成功"

    if ($Tag -match '^v\d+\.\d+$') {
        Invoke-Git -Arguments @('push','origin',$Tag) -WorkingDir $RepoPath | Out-Null
        Write-Log "[标签] 标签 $Tag 已推送"
    }

    Write-Log "=========================================="
    Write-Log "上传完成！"
    Write-Log "账号: $Owner"
    Write-Log "=========================================="
    return $true
}

# ============================================================
# GUI 界面
# ============================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "GitHub 上传工具 v1.1 多账号版"
$form.Size = New-Object System.Drawing.Size(640, 750)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 244, 248)

# ---- 标题 ----
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "GitHub 一键上传工具"
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(25, 80, 160)
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.Size = New-Object System.Drawing.Size(400, 32)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "多账号版  |  作者：诗绪  |  2026-09-27"
$lblSub.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(120, 130, 145)
$lblSub.Location = New-Object System.Drawing.Point(22, 48)
$lblSub.Size = New-Object System.Drawing.Size(500, 20)
$form.Controls.Add($lblSub)

# ---- 模式选择 ----
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = "上传模式"
$grpMode.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$grpMode.ForeColor = [System.Drawing.Color]::FromArgb(40, 50, 65)
$grpMode.Location = New-Object System.Drawing.Point(20, 80)
$grpMode.Size = New-Object System.Drawing.Size(580, 60)
$form.Controls.Add($grpMode)

$rbOverwrite = New-Object System.Windows.Forms.RadioButton
$rbOverwrite.Text = "覆盖上传（用压缩包整体替换仓库）"
$rbOverwrite.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$rbOverwrite.Location = New-Object System.Drawing.Point(15, 25)
$rbOverwrite.Size = New-Object System.Drawing.Size(280, 24)
$rbOverwrite.Checked = $true
$grpMode.Controls.Add($rbOverwrite)

$rbIncremental = New-Object System.Windows.Forms.RadioButton
$rbIncremental.Text = "增量推送（推送本地已改的文件）"
$rbIncremental.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$rbIncremental.Location = New-Object System.Drawing.Point(310, 25)
$rbIncremental.Size = New-Object System.Drawing.Size(260, 24)
$grpMode.Controls.Add($rbIncremental)

# ---- GitHub 账号 ----
$lblAccount = New-Object System.Windows.Forms.Label
$lblAccount.Text = "GitHub 账号："
$lblAccount.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$lblAccount.Location = New-Object System.Drawing.Point(20, 158)
$lblAccount.Size = New-Object System.Drawing.Size(90, 22)
$form.Controls.Add($lblAccount)

$script:savedConfig = Read-Config
$cmbAccount = New-Object System.Windows.Forms.ComboBox
$cmbAccount.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$cmbAccount.Location = New-Object System.Drawing.Point(105, 155)
$cmbAccount.Size = New-Object System.Drawing.Size(200, 28)
$cmbAccount.DropDownStyle = 'DropDown'
foreach ($acc in $script:savedConfig.accounts) { $cmbAccount.Items.Add($acc) | Out-Null }
$cmbAccount.Text = $script:savedConfig.lastAccount
$form.Controls.Add($cmbAccount)

$lblAccountHint = New-Object System.Windows.Forms.Label
$lblAccountHint.Text = "（可输入其他账号，首次使用会弹登录窗）"
$lblAccountHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblAccountHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 150, 160)
$lblAccountHint.Location = New-Object System.Drawing.Point(315, 158)
$lblAccountHint.Size = New-Object System.Drawing.Size(280, 20)
$form.Controls.Add($lblAccountHint)

# ---- 仓库选择 ----
$lblRepo = New-Object System.Windows.Forms.Label
$lblRepo.Text = "目标仓库："
$lblRepo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$lblRepo.Location = New-Object System.Drawing.Point(20, 195)
$lblRepo.Size = New-Object System.Drawing.Size(80, 22)
$form.Controls.Add($lblRepo)

$cmbRepo = New-Object System.Windows.Forms.ComboBox
$cmbRepo.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$cmbRepo.Location = New-Object System.Drawing.Point(105, 192)
$cmbRepo.Size = New-Object System.Drawing.Size(200, 28)
$cmbRepo.DropDownStyle = 'DropDown'
$cmbRepo.Items.AddRange((Get-LocalRepos))
if ($script:savedConfig.lastRepo -and $cmbRepo.Items.Contains($script:savedConfig.lastRepo)) {
    $cmbRepo.SelectedItem = $script:savedConfig.lastRepo
} elseif ($cmbRepo.Items.Count -gt 0) {
    $cmbRepo.SelectedIndex = 0
}
$form.Controls.Add($cmbRepo)

$lblRepoHint = New-Object System.Windows.Forms.Label
$lblRepoHint.Text = "（可填「仓库名」或「所有者/仓库名」）"
$lblRepoHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblRepoHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 150, 160)
$lblRepoHint.Location = New-Object System.Drawing.Point(315, 195)
$lblRepoHint.Size = New-Object System.Drawing.Size(280, 20)
$form.Controls.Add($lblRepoHint)

# ---- 压缩包选择 ----
$lblZip = New-Object System.Windows.Forms.Label
$lblZip.Text = "新压缩包："
$lblZip.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$lblZip.Location = New-Object System.Drawing.Point(20, 232)
$lblZip.Size = New-Object System.Drawing.Size(80, 22)
$form.Controls.Add($lblZip)

$txtZip = New-Object System.Windows.Forms.TextBox
$txtZip.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$txtZip.Location = New-Object System.Drawing.Point(105, 229)
$txtZip.Size = New-Object System.Drawing.Size(400, 24)
$form.Controls.Add($txtZip)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "浏览..."
$btnBrowse.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$btnBrowse.Location = New-Object System.Drawing.Point(515, 227)
$btnBrowse.Size = New-Object System.Drawing.Size(85, 28)
$form.Controls.Add($btnBrowse)

# ---- 版本号 ----
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "版本号："
$lblVersion.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$lblVersion.Location = New-Object System.Drawing.Point(20, 269)
$lblVersion.Size = New-Object System.Drawing.Size(80, 22)
$form.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$txtVersion.Location = New-Object System.Drawing.Point(105, 266)
$txtVersion.Size = New-Object System.Drawing.Size(120, 24)
$txtVersion.Text = "v2.0"
$form.Controls.Add($txtVersion)

$lblVersionHint = New-Object System.Windows.Forms.Label
$lblVersionHint.Text = "（用于 commit 说明和标签，如 v2.1）"
$lblVersionHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblVersionHint.ForeColor = [System.Drawing.Color]::FromArgb(140, 150, 160)
$lblVersionHint.Location = New-Object System.Drawing.Point(235, 269)
$lblVersionHint.Size = New-Object System.Drawing.Size(280, 20)
$form.Controls.Add($lblVersionHint)

# ---- 版本说明 ----
$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Text = "版本说明："
$lblDesc.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$lblDesc.Location = New-Object System.Drawing.Point(20, 306)
$lblDesc.Size = New-Object System.Drawing.Size(85, 22)
$form.Controls.Add($lblDesc)

$txtDesc = New-Object System.Windows.Forms.TextBox
$txtDesc.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$txtDesc.Location = New-Object System.Drawing.Point(105, 303)
$txtDesc.Size = New-Object System.Drawing.Size(495, 24)
$form.Controls.Add($txtDesc)

# ---- 网络检测按钮 ----
$btnTestNet = New-Object System.Windows.Forms.Button
$btnTestNet.Text = "测试网络"
$btnTestNet.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$btnTestNet.Location = New-Object System.Drawing.Point(20, 342)
$btnTestNet.Size = New-Object System.Drawing.Size(100, 32)
$btnTestNet.BackColor = [System.Drawing.Color]::FromArgb(230, 240, 250)
$form.Controls.Add($btnTestNet)

# ---- 上传按钮 ----
$btnUpload = New-Object System.Windows.Forms.Button
$btnUpload.Text = "一键上传"
$btnUpload.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
$btnUpload.ForeColor = [System.Drawing.Color]::White
$btnUpload.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
$btnUpload.FlatStyle = 'Flat'
$btnUpload.Location = New-Object System.Drawing.Point(130, 342)
$btnUpload.Size = New-Object System.Drawing.Size(470, 38)
$form.Controls.Add($btnUpload)

# ---- 日志框 ----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "执行日志："
$lblLog.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$lblLog.Location = New-Object System.Drawing.Point(20, 395)
$lblLog.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($lblLog)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 34, 40)
$script:txtLog.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 180)
$script:txtLog.Location = New-Object System.Drawing.Point(20, 417)
$script:txtLog.Size = New-Object System.Drawing.Size(580, 285)
$form.Controls.Add($script:txtLog)

# ============================================================
# 事件绑定
# ============================================================

# ---- 浏览压缩包 ----
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "压缩包 (*.zip)|*.zip|所有文件 (*.*)|*.*"
    $dlg.Title = "选择要上传的压缩包"
    $dlg.InitialDirectory = "D:\"
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtZip.Text = $dlg.FileName
        # 自动猜测版本号（从文件名提取）
        if ($dlg.FileName -match 'v(\d+)\.(\d+)') { $txtVersion.Text = "v$($Matches[1]).$($Matches[2])" }
    }
})

# ---- 模式切换 ----
$rbOverwrite.Add_CheckedChanged({
    if ($rbOverwrite.Checked) {
        $txtZip.Enabled = $true
        $btnBrowse.Enabled = $true
        $txtZip.BackColor = [System.Drawing.Color]::White
    } else {
        $txtZip.Enabled = $false
        $btnBrowse.Enabled = $false
        $txtZip.BackColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
    }
})

# ---- 测试网络 ----
$btnTestNet.Add_Click({
    $btnTestNet.Enabled = $false
    $script:txtLog.Clear()
    Write-Log "开始检测 GitHub 连通性..."
    $connected = Repair-GitHubNetwork
    if ($connected) {
        Write-Log "[结果] 网络正常，可以上传"
    } else {
        Write-Log "[结果] 所有节点不通，请检查网络"
    }
    $btnTestNet.Enabled = $true
})

# ---- 一键上传 ----
$btnUpload.Add_Click({
    $btnUpload.Enabled = $false
    $btnUpload.Text = "正在执行..."
    $script:txtLog.Clear()
    try {
        $account = $cmbAccount.Text.Trim()
        $repoName = $cmbRepo.Text.Trim()
        $version = $txtVersion.Text.Trim()
        $desc = $txtDesc.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($account)) { Write-Log "[错误] 请填写 GitHub 账号"; throw "stop" }
        if ($account -notmatch '^[A-Za-z0-9-]+$') { Write-Log "[错误] 账号名只能包含字母、数字、连字符"; throw "stop" }
        if ([string]::IsNullOrWhiteSpace($repoName)) { Write-Log "[错误] 请填写仓库名"; throw "stop" }
        if (-not $version -match '^v?\d+\.\d+$') { Write-Log "[错误] 版本号格式应为 v2.1 这样的形式"; throw "stop" }
        if ($version -notmatch '^v') { $version = "v$version" }

        # 保存配置（记住账号和仓库）
        Save-Config -Account $account -Repo $repoName

        $success = $false
        if ($rbOverwrite.Checked) {
            # 覆盖上传
            $zipPath = $txtZip.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($zipPath)) { Write-Log "[错误] 请选择压缩包"; throw "stop" }
            $success = Start-OverwriteUpload -ZipPath $zipPath -RepoName $repoName -Account $account -Version $version -Desc $desc
        } else {
            # 增量推送
            $success = Start-IncrementalPush -RepoName $repoName -Account $account -Version $version -Desc $desc
        }
        if ($success) {
            $btnUpload.BackColor = [System.Drawing.Color]::FromArgb(40, 160, 80)
            $btnUpload.Text = "上传成功"
        } else {
            $btnUpload.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
            $btnUpload.Text = "上传失败，查看日志"
        }
    } catch {
        if ($_.Exception.Message -ne 'stop') { Write-Log "[异常] $($_.Exception.Message)" }
        $btnUpload.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $btnUpload.Text = "上传失败，查看日志"
    } finally {
        Start-Sleep -Milliseconds 300
        $btnUpload.Enabled = $true
        # 3秒后恢复按钮状态（$this 指定时器自身，闭包捕获按钮对象，避免作用域丢失导致 null 报错）
        $btn = $btnUpload
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 3000
        $timer.Add_Tick({
            $btn.Text = "一键上传"
            $btn.BackColor = [System.Drawing.Color]::FromArgb(25, 118, 210)
            $this.Stop(); $this.Dispose()
        }.GetNewClosure())
        $timer.Start()
    }
})

# ---- 启动提示 ----
Write-Log "工具已就绪。点击「一键上传」开始，或先「测试网络」"
Write-Log "提示：账号可切换，首次用新账号会弹 GitHub 登录窗"
Write-Log "      仓库可填「仓库名」或「所有者/仓库名」（协作场景）"
Write-Log "      覆盖上传会用压缩包整体替换仓库内容"
Write-Log "      增量推送只提交你改动的文件"

# ---- 显示窗口 ----
[void]$form.ShowDialog()
$form.Dispose()
