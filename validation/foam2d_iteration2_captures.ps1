$ErrorActionPreference='Stop'
$engine='C:\Users\ehort\Documents\Godot 4.7\Godot_v4.7.1-stable_win64_console.exe'
$cases=@(
  @{name='current_trail';mode='combined';view='trail';scenario='forward'},
  @{name='previous_trail';mode='previous2d';view='trail';scenario='forward'},
  @{name='current_side';mode='combined';view='side';scenario='forward'},
  @{name='previous_side';mode='previous2d';view='side';scenario='forward'},
  @{name='current_reverse';mode='combined';view='trail';scenario='reverse'},
  @{name='previous_reverse';mode='previous2d';view='trail';scenario='reverse'}
)
New-Item -ItemType Directory -Path 'temp/foam2d/iteration2_captures' -Force | Out-Null
foreach($case in $cases){
  $output="res://temp/foam2d/iteration2_captures/$($case.name)"
  & $engine --path . --fixed-fps 60 --disable-vsync --script res://validation/foam2d_probe.gd -- "--mode=$($case.mode)" --vehicles=1 --frames=600 "--scenario=$($case.scenario)" "--view=$($case.view)" --sea=1 --shots=yes "--out=$output" *> "temp/foam2d/iteration2_captures/$($case.name).log"
  if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath "temp/foam2d/iteration2_captures/$($case.name)/report.json")){throw "Capture failed: $($case.name)"}
  Write-Output "FOAM2D_CAPTURE $($case.name)"
}
