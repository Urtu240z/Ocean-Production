$ErrorActionPreference='Stop'
$enginePath='C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe'
foreach($sea in @(1,0)) {
  foreach($view in @('side','top')) {
    foreach($mode in @('original','contact','wake','combined','f1f2')) {
      $name="${mode}_${sea}_${view}"
      $clip=if($mode -eq 'contact' -and $sea -eq 1 -and $view -eq 'side'){'yes'}else{'no'}
      & $enginePath --path . --fixed-fps 60 --disable-vsync --script res://validation/foam2d_probe.gd -- "--mode=$mode" "--out=res://temp/foam2d/captures/$name" "--view=$view" "--sea=$sea" --frames=900 --shots=yes "--clip=$clip" > "temp/foam2d/captures/$name.log" 2>&1
      if($LASTEXITCODE -ne 0) { throw "Capture failed: $name" }
      Write-Output "FOAM2D_CAPTURE $name"
    }
  }
}
foreach($mode in @('original','contact','combined')) {
  & $enginePath --path . --fixed-fps 60 --disable-vsync --script res://validation/foam2d_probe.gd -- "--mode=$mode" "--out=res://temp/foam2d/captures/underside_$mode" --view=underside --sea=1 --frames=240 --shots=yes > "temp/foam2d/captures/underside_$mode.log" 2>&1
  if($LASTEXITCODE -ne 0) { throw "Underside capture failed: $mode" }
  Write-Output "FOAM2D_CAPTURE underside_$mode"
}
