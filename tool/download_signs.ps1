# Downloads hand-sign illustrations from Wikimedia Commons into assets/signs/.
# Filenames match SignAssets resolution: label -> lowercase slug (e.g. "Letter A" -> letter_a.png).
#
# Sources (Wikimedia Commons, freely licensed — see ATTRIBUTION.md):
#   - Alphabet: "Sign language A.svg".."Sign language Z.svg" (Gallaudet-TT derived, PD)
#   - Numbers:  "Asl alphabet gallaudet (zero..ten).svg"     (Gallaudet-TT derived, PD)
#   - Words:    ASL photo set ("ASL <shape>@<location>.jpg"), glosses verified via
#               each file's description ("posture of the ASL sign <GLOSS>").
#
# SVGs are rasterized to PNG at 256px via Special:FilePath?width=256.

$ErrorActionPreference = 'Continue'
$ua = 'ThandoSignApp/1.0 (educational app; contact: ngwenyathando@gmail.com)'
$outDir = Join-Path $PSScriptRoot '..\assets\signs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$map = [ordered]@{}

# ---- Alphabet ------------------------------------------------------
foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') {
  $map["letter_$($c.ToString().ToLower())"] = "Sign language $c.svg"
}

# ---- Numbers -------------------------------------------------------
# zero: Gallaudet-style SVG illustration. one-ten: LSQ/ASL photo set
# (per file descriptions the digit shapes are identical in LSQ and ASL).
$map['zero'] = 'Asl alphabet gallaudet (zero).svg'
$numWords = 'one','two','three','four','five','six','seven','eight','nine','ten'
for ($i = 0; $i -lt $numWords.Count; $i++) {
  $map[$numWords[$i]] = "LSQ $($i + 1).jpg"
}

# ---- Words (label slug -> Commons file) ----------------------------
$wordMap = [ordered]@{
  'hello'                 = 'ASL FlatB@SideNeckhigh-PalmForward.jpg'
  'goodbye'               = 'ASL FlatB@InsideNeckhigh-PalmForward.jpg'
  'see_you_later'         = 'ASL FlatB@InsideNeckhigh-PalmForward.jpg'
  'thank_you'             = 'ASL OpenB@Chin-PalmBack.jpg'
  'welcome'               = 'ASL FlatB@Trunk-PalmUp.jpg'
  'welcome_back'          = 'ASL FlatB@FromTrunk-PalmUp.jpg'
  'yes'                   = 'ASL S@Side-PalmForward.jpg'
  'no'                    = 'ASL FlatO@Side-PalmForward.jpg'
  'good'                  = 'ASL OpenB@Palm-PalmUp-OpenB@CenterChesthigh-PalmUp.jpg'
  'bad'                   = 'ASL OpenB@FromChin-PalmDown.jpg'
  'okay'                  = 'ASL K@Side-PalmForward.jpg'
  'understand'            = 'ASL 1@NearSfhead-PalmBack.jpg'
  'i_do_not_understand'   = 'ASL SmallO@NearSfhead-PalmBack Release DONT-UNDERSTAND 2.jpg'
  'fine'                  = 'ASL 5@Sternum-FingerUp Contact.jpg'
  'i_am_fine'             = 'ASL 5@Sternum-FingerUp Contact.jpg'
  'how'                   = 'ASL BentB@Ulnar-PalmUp-BentB@CenterChesthigh-PalmUp.jpg'
  'how_are_you'           = 'ASL BentB@Ulnar-PalmUp-BentB@CenterChesthigh-PalmUp.jpg'
  'how_much'              = 'ASL Claw5@InsideChesthigh-PalmUp-Claw5@InsideChesthigh-PalmUp.jpg'
  'what'                  = 'ASL Claw5@SideTrunkhigh-PalmUp-Claw2@SideTrunkhigh-PalmUp Sidetoside-Sidetoside 2.jpg'
  'where'                 = 'ASL 1@Side-PalmForward.jpg'
  'who'                   = 'ASL L@Chin-ThumbBack.jpg'
  'why'                   = 'ASL Y@Sfhead.jpg'
  'name'                  = 'ASL H@NearRadialFinger-H@CenterChesthigh.jpg'
  'my_name_is'            = 'ASL H@NearRadialFinger-H@CenterChesthigh.jpg'
  'what_is_your_name'     = 'ASL H@RadialFinger-H@CenterChesthigh.jpg'
  'you'                   = 'ASL 1@InsideChesthigh-FingerForward.jpg'
  'me'                    = 'ASL 1@Sternum-FingerBack.jpg'
  'want'                  = 'ASL Claw5@InsideChesthigh-PalmUp-Claw5@InsideChesthigh-PalmUp WANT 1.jpg'
  'go'                    = 'ASL 1@NearHand-FingerUp-1@InsideChesthigh-FingerUp.jpg'
  'sit'                   = 'ASL H@BackFinger-FingerAcrossPalmDown-H@CenterChesthigh-PalmDown.jpg'
  'stand'                 = 'ASL V@Palm-FingerDown-OpenB@CenterTrunkhigh-PalmUp.jpg'
  'food'                  = 'ASL FlatO@Mouth-PalmBack.jpg'
  'eat'                   = 'ASL FlatO@NearMouth-PalmBack-FlatO@Mouth-PalmBack.jpg'
  'drink'                 = 'ASL C@NearMouth-TipForward.jpg'
  'happy'                 = 'ASL OpenB@IpsiChest-PalmBack-OpenB@IpsiChest-PalmBack.jpg'
  'sad'                   = 'ASL 5@NearInsideNosehigh-PalmBack.jpg'
  'angry'                 = 'ASL Claw5@NearNose-PalmBack.jpg'
  'i_love_you'            = 'ASL ILY@Side-PalmForward.jpg'
  'love'                  = 'ASL 1@BasePalm-OpenB@CenterTrunkhigh-PalmUp.jpg'
  'sign_language'         = 'ASL ILY@Side-PalmForward.jpg'
  'sleep'                 = 'ASL 5@InsideNosehigh-PalmDown-5@InsideTrunkhigh-PalmUp.jpg'
  'write'                 = 'ASL FlatO@Palm-PalmDown-OpenB@CenterChesthigh-PalmUp.jpg'
  'think'                 = 'ASL 1@Sfhead-PalmDown.jpg'
  'father'                = 'ASL A@Forehead.jpg'
  'maybe'                 = 'ASL BentB@Sfhead BentB@FromSfhead-PalmAside 1.jpg'
}
foreach ($k in $wordMap.Keys) { $map[$k] = $wordMap[$k] }

# ---- Download ------------------------------------------------------
$ok = 0; $fail = @()
foreach ($slug in $map.Keys) {
  $src = $map[$slug]
  $ext = if ($src -like '*.svg') { 'png' } else { 'jpg' }
  $dest = Join-Path $outDir "$slug.$ext"
  if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 1024) { $ok++; continue }
  $url = 'https://commons.wikimedia.org/wiki/Special:FilePath/' +
         [uri]::EscapeDataString($src) + '?width=256'
  try {
    Invoke-WebRequest -Uri $url -OutFile $dest -UserAgent $ua -MaximumRedirection 10
    if ((Get-Item $dest).Length -lt 1024) { throw "tiny file ($((Get-Item $dest).Length) bytes)" }
    $ok++
    Write-Host "ok  $slug <- $src"
  } catch {
    $fail += "$slug <- $src : $($_.Exception.Message)"
    Write-Host "FAIL $slug <- $src"
    try { if (Test-Path $dest) { Remove-Item $dest -Force } } catch {}
  }
  Start-Sleep -Milliseconds 800
}
Write-Host "`nDone: $ok ok, $($fail.Count) failed"
$fail | ForEach-Object { Write-Host $_ }
