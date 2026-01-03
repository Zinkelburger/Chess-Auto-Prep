#!/usr/bin/env python3
"""
Test LC0 Setup

This script verifies that LC0 is properly configured and can analyze positions.
Run this first to ensure everything is working before using the main analysis tools.
"""

import asyncio
import os
import sys
from wld_calculator import calculate_wld, DEFAULT_LC0_PATH

async def test_lc0_setup():
    """Test that LC0 is working properly"""
    print("LC0 SETUP TEST")
    print("=" * 50)

    # Check if LC0 binary exists
    print(f"1. Checking LC0 binary at: {DEFAULT_LC0_PATH}")
    if os.path.exists(DEFAULT_LC0_PATH):
        print("   ✓ LC0 binary found")
    else:
        print("   ✗ LC0 binary not found")
        print(f"   Please check the path: {DEFAULT_LC0_PATH}")
        print("   You can specify a different path using --engine-path")
        return False

    # Check if binary is executable
    if os.access(DEFAULT_LC0_PATH, os.X_OK):
        print("   ✓ LC0 binary is executable")
    else:
        print("   ✗ LC0 binary is not executable")
        print("   Try: chmod +x " + DEFAULT_LC0_PATH)
        return False

    # Test basic analysis
    print("\n2. Testing basic analysis...")
    test_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    try:
        result = await calculate_wld(test_fen, analysis_time=1.0)

        if "error" in result:
            print(f"   ✗ Analysis failed: {result['error']}")
            print("\n   Common issues:")
            print("   • Missing neural network file (*.pb.gz)")
            print("   • Incorrect OpenCL/CUDA setup")
            print("   • Try --backend cpu")
            return False
        else:
            print("   ✓ Basic analysis successful")
            print(f"   Win: {result['win_pct']:.1f}%, Draw: {result['draw_pct']:.1f}%, Loss: {result['loss_pct']:.1f}%")
            print(f"   Depth: {result['depth']}, Nodes: {result['total_nodes']:,}")

    except Exception as e:
        print(f"   ✗ Exception during analysis: {e}")
        return False

    # Test GPU backend (if available)
    print("\n3. Testing GPU backend (OpenCL)...")
    try:
        result = await calculate_wld(test_fen, analysis_time=0.5, backend="opencl")
        if "error" not in result:
            print("   ✓ OpenCL backend working")
        else:
            print("   ! OpenCL backend failed, but CPU should work")
    except:
        print("   ! OpenCL backend failed, but CPU should work")

    print("\n4. Testing CPU backend...")
    try:
        result = await calculate_wld(test_fen, analysis_time=0.5, backend="cpu")
        if "error" not in result:
            print("   ✓ CPU backend working")
        else:
            print(f"   ✗ CPU backend failed: {result['error']}")
            return False
    except Exception as e:
        print(f"   ✗ CPU backend failed: {e}")
        return False

    print("\n" + "=" * 50)
    print("✓ LC0 SETUP TEST PASSED")
    print("\nYour LC0 setup is working correctly!")
    print("You can now run the analysis tools:")
    print("• python wld_calculator.py")
    print("• python sharpness_analyzer.py")
    print("• python game_analyzer.py --sample-game")
    print("• python demo.py")

    return True

async def main():
    success = await test_lc0_setup()
    if not success:
        print("\n" + "=" * 50)
        print("✗ LC0 SETUP TEST FAILED")
        print("\nPlease fix the issues above before using the analysis tools.")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())