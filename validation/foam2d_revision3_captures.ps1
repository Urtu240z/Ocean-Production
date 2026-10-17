$ErrorActionPreference='Stop'
$engine='C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe'
$root='temp/foam2d/revision3_captures'
New-Item -ItemType Directory -Path $root -Force | Out-Null
foreach($view in @('near_top','trail','side','reverse')){
  foreach($version in @('current','previous')){
    $mode=if($version -eq 'current'){'combined'}else{'previous_revision'}
    $scenario=if($view -eq 'reverse'){'reverse'}else{'forward'}
    $camera=if($view -eq 'reverse'){'trail'}else{$view}
    $name="${version}_$view"
    & $engine --path . --fixed-fps 60 --disable-vsync --script res://validation/foam2d_probe.gd -- "--mode=$mode" --vehicles=1 --frames=600 "--scenario=$scenario" "--view=$camera" --sea=1 --shots=yes "--out=res://$root/$name" *> "$root/$name.log"
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath "$root/$name/report.json")){throw "Capture failed: $name"}
    Write-Output "FOAM2D_REV3 $name"
  }
}
& $engine --path . --fixed-fps 60 --disable-vsync --script res://validation/foam2d_probe.gd -- --mode=combined --vehicles=1 --frames=240 --view=near_top --sea=1 --shots=yes --debug=3 "--out=res://$root/contour" *> "$root/contour.log"
if($LASTEXITCODE -ne 0){throw 'Contour capture failed'}
