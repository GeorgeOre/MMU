#!/bin/bash

# Summary of flags
#
#   Flag    |   Purpose
# --hide    | Disables GTK after processing
# --compileOSVVM <-- yep

# Stop script if any command fails
set -e

GHDL="/usr/bin/ghdl"
GTKWAVE="/usr/bin/gtkwave"

OSVVM_PATH="/home/gore/Downloads/libs/OsvvmLibraries/osvvm/"
# I know this is annoying but please just hide it with the side arrow
OSVVM_FILES=(
    "IfElsePkg.vhd"
    "OsvvmTypesPkg.vhd"
    "OsvvmScriptSettingsPkg.vhd"
    "OsvvmScriptSettingsPkg_default.vhd"
    "OsvvmSettingsPkg.vhd"
    "OsvvmSettingsPkg_default.vhd"
    "TextUtilPkg.vhd"
    "ResolutionPkg.vhd"
    "NamePkg.vhd"
    "OsvvmGlobalPkg.vhd"
    "CoverageVendorApiPkg_default.vhd"
    "TranscriptPkg.vhd"
    "deprecated/FileLinePathPkg_c.vhd"
    "deprecated/LanguageSupport2019Pkg_c.vhd"
    "AlertLogPkg.vhd"
    "TbUtilPkg.vhd"
    "NameStorePkg.vhd"
    "MessageListPkg.vhd"
    "SortListPkg_int.vhd"
    "RandomBasePkg.vhd"
    "RandomPkg.vhd"
    "RandomProcedurePkg.vhd"
    "CoveragePkg.vhd"
    "DelayCoveragePkg.vhd"
    "deprecated/ClockResetPkg_2024_05.vhd"
    "ResizePkg.vhd"
    "ScoreboardGenericPkg.vhd"
    "ScoreboardPkg_IntV.vhd"
    "ScoreboardPkg_slv.vhd"
    "ScoreboardPkg_int.vhd"
    "ScoreboardPkg_signed.vhd"
    "ScoreboardPkg_unsigned.vhd"
    "MemorySupportPkg.vhd"
    "MemoryGenericPkg.vhd"
    "MemoryPkg.vhd"
    "ReportPkg.vhd"
    "deprecated/RandomPkg2019_c.vhd"
    "OsvvmContext.vhd"
)

# Check for --compileOSVVM argument to compile OSVVM (Add your own path if you want to use)
for arg in "$@"; do
    if [ "$arg" == "--compileOSVVM" ]; then
        echo "Compile OSVVM..."
        for file in "${OSVVM_FILES[@]}"; do
            echo "Analyzing $file..."
            $GHDL -a --std=08 --work=osvvm $OSVVM_PATH"$file"
        done
        break
    fi
done

# Check for --hide argument to hide waveform display
VIEW_WAVEFORM=true
for arg in "$@"; do
    if [ "$arg" == "--hide" ]; then
        VIEW_WAVEFORM=false
        break
    fi
done

# Include VHDL files
TB_NAME="tb_mmu"
WAVEFORM_NAME="tb_mmu"
VHDL_FILES=(
    "mmu.vhd"
    "tb_mmu.vhd"
    # "tb_mmu_osvvm.vhd"
)

# Analyze
echo "Analyzing..."
for file in "${VHDL_FILES[@]}"; do
    # echo -e "\t$file..."
    $GHDL -a --std=08 "$file"
done

# Elaborate
echo "Elaborating..."
$GHDL -e --std=08 $TB_NAME


# Run test
echo "Running..."
$GHDL -r --std=08 $TB_NAME --vcd="$TB_NAME.vcd" --stop-time=1000us 
echo "Finished running..."

# George's GTK scaling settings
SIGNAL_SIZE="fontname_signals Monospace 20"
WAVE_SIZE="fontname_waves Monospace 8"


# Waveform viewer
if [ "$VIEW_WAVEFORM" == true ]; then
    if [ -f "$TB_NAME.gtkw" ]; then
        $GTKWAVE "$TB_NAME.gtkw" --rcvar "$SIGNAL_SIZE" --rcvar "$WAVE_SIZE"        
    else
        $GTKWAVE "$TB_NAME.vcd" --rcvar "$SIGNAL_SIZE" --rcvar "$WAVE_SIZE"
    fi
fi
