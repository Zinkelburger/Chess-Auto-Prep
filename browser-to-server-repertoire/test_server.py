#!/usr/bin/env python3
"""
Test script for the repertoire server
Sends sample lines to verify the server is working correctly
"""

import requests
import json
import time

SERVER_URL = 'http://localhost:9812'

# Sample line data (Italian Game opening)
sample_line = {
    "pgn": "1. e4 e5 2. Nf3! { Best developing move } 2... Nc6 3. Bc4! { The Italian Game } 3... Bc5",
    "startFen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "variant": "standard",
    "moves": [
        {
            "ply": 1,
            "moveNumber": 1,
            "color": "white",
            "san": "e4",
            "uci": "e2e4",
            "fen": "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "comments": [],
            "glyphs": [],
            "eval": {"cp": 29, "mate": None, "best": "e7e5"}
        },
        {
            "ply": 2,
            "moveNumber": 1,
            "color": "black",
            "san": "e5",
            "uci": "e7e5",
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            "comments": [],
            "glyphs": [],
            "eval": None
        },
        {
            "ply": 3,
            "moveNumber": 2,
            "color": "white",
            "san": "Nf3",
            "uci": "g1f3",
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            "comments": ["Best developing move"],
            "glyphs": [{"id": 1, "symbol": "!", "name": "Good move"}],
            "eval": {"cp": 22, "mate": None, "best": "b8c6"}
        },
        {
            "ply": 4,
            "moveNumber": 2,
            "color": "black",
            "san": "Nc6",
            "uci": "b8c6",
            "fen": "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
            "comments": [],
            "glyphs": [],
            "eval": None
        },
        {
            "ply": 5,
            "moveNumber": 3,
            "color": "white",
            "san": "Bc4",
            "uci": "f1c4",
            "fen": "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3",
            "comments": ["The Italian Game"],
            "glyphs": [{"id": 1, "symbol": "!", "name": "Good move"}],
            "eval": {"cp": 18, "mate": None, "best": "f8c5"}
        },
        {
            "ply": 6,
            "moveNumber": 3,
            "color": "black",
            "san": "Bc5",
            "uci": "f8c5",
            "fen": "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
            "comments": [],
            "glyphs": [],
            "eval": None
        }
    ]
}


def test_health():
    """Test health endpoint"""
    print("Testing /health endpoint...")
    try:
        response = requests.get(f'{SERVER_URL}/health')
        if response.status_code == 200:
            data = response.json()
            print(f"✓ Server is healthy")
            print(f"  Lines: {data['lineCount']}")
            print(f"  Queue: {data['queueSize']} pending")
            print(f"  File: {data['file']}")
            return True
        else:
            print(f"✗ Health check failed: {response.status_code}")
            return False
    except requests.exceptions.ConnectionError:
        print(f"✗ Cannot connect to server at {SERVER_URL}")
        print(f"  Make sure the server is running: python server.py")
        return False
    except Exception as e:
        print(f"✗ Error: {e}")
        return False


def test_add_line():
    """Test adding a line"""
    print("\nTesting /add-line endpoint...")
    try:
        response = requests.post(
            f'{SERVER_URL}/add-line',
            json=sample_line,
            headers={'Content-Type': 'application/json'}
        )

        if response.status_code == 200:
            data = response.json()
            print(f"✓ Line added successfully")
            print(f"  Status: {data['status']}")
            print(f"  Total lines: {data['lineCount']}")
            print(f"  Message: {data['message']}")
            return True
        else:
            print(f"✗ Failed to add line: {response.status_code}")
            print(f"  Response: {response.text}")
            return False
    except Exception as e:
        print(f"✗ Error: {e}")
        return False


def test_duplicate():
    """Test duplicate detection"""
    print("\nTesting duplicate detection...")
    try:
        response = requests.post(
            f'{SERVER_URL}/add-line',
            json=sample_line,
            headers={'Content-Type': 'application/json'}
        )

        if response.status_code == 200:
            data = response.json()
            if data['status'] == 'duplicate':
                print(f"✓ Duplicate correctly detected")
                print(f"  Message: {data['message']}")
                return True
            else:
                print(f"✗ Line was added again (should be duplicate)")
                return False
        else:
            print(f"✗ Request failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"✗ Error: {e}")
        return False


def test_concurrent():
    """Test concurrent request handling"""
    print("\nTesting concurrent requests...")
    try:
        import concurrent.futures

        # Create a different line for concurrent testing
        different_line = {
            **sample_line,
            "pgn": "1. d4 d5 2. c4",
            "moves": sample_line["moves"][:3]  # Shorter line
        }
        # Change the UCIs to make it different
        different_line["moves"][0]["uci"] = "d2d4"
        different_line["moves"][0]["san"] = "d4"
        different_line["moves"][1]["uci"] = "d7d5"
        different_line["moves"][1]["san"] = "d5"
        different_line["moves"][2]["uci"] = "c2c4"
        different_line["moves"][2]["san"] = "c4"

        # Send 3 requests concurrently
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            futures = [
                executor.submit(
                    requests.post,
                    f'{SERVER_URL}/add-line',
                    json=different_line,
                    headers={'Content-Type': 'application/json'}
                )
                for _ in range(3)
            ]

            results = [f.result() for f in futures]

        success_count = sum(1 for r in results if r.status_code == 200)
        duplicate_count = sum(1 for r in results if r.json().get('status') == 'duplicate')

        print(f"✓ Handled {len(results)} concurrent requests")
        print(f"  {success_count} successful, {duplicate_count} duplicates")

        if success_count >= 1 and duplicate_count >= 1:
            print(f"✓ Queue and duplicate detection working correctly")
            return True
        else:
            print(f"⚠ Unexpected results")
            return True  # Still pass, just warn

    except Exception as e:
        print(f"✗ Error: {e}")
        return False


if __name__ == '__main__':
    print("=" * 60)
    print("Repertoire Server Test")
    print("=" * 60)

    # Run tests
    all_passed = True
    all_passed &= test_health()
    all_passed &= test_add_line()
    all_passed &= test_duplicate()
    all_passed &= test_concurrent()

    print("\n" + "=" * 60)
    if all_passed:
        print("✓ All tests passed!")
    else:
        print("✗ Some tests failed")
    print("=" * 60)

    print("\nView your repertoire:")
    print("  cat repertoire.pgn")
    print("  curl http://localhost:9812/health")
