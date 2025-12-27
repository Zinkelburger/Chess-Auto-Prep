
import chess.pgn
import sys
import os
import json

# Add the project root to sys.path
sys.path.append('/home/anbernal/Documents/Chess-Auto-Prep')
sys.path.append('/home/anbernal/Documents/Chess-Auto-Prep/poopchess')

# Configure Django settings
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
import django
django.setup()

from courses.models import Course

def test_generate_tree_with_benoni():
    print("--- Testing generate_tree with real Benoni.pgn ---")
    
    # Get the course
    try:
        course = Course.objects.get(title='The Modern Benoni')
        print(f"Found course: {course.title}")
        print(f"PGN Path: {course.pgn_file.path}")
        
        # Manually trigger tree generation
        print("Regenerating tree...")
        course.generate_tree()
        
        # Check the result
        tree_path = course.tree_json_file.path
        print(f"Tree generated at: {tree_path}")
        
        if not os.path.exists(tree_path):
            print("ERROR: Tree file not created!")
            return

        with open(tree_path, 'r') as f:
            data = json.load(f)
            
        print("--- Tree JSON Analysis ---")
        print(f"Root FEN: {data.get('fen')}")
        print(f"Root Moves: {list(data.get('moves', {}).keys())}")
        
        # Verify specific moves exist
        if 'd4' in data.get('moves', {}):
            print("SUCCESS: Found 'd4' in root moves.")
            d4_node = data['moves']['d4']
            if 'Nf6' in d4_node.get('moves', {}):
                print("SUCCESS: Found 'Nf6' after 'd4'.")
                # Drill down deeper
                nf6_node = d4_node['moves']['Nf6']
                print(f"Moves after 1. d4 Nf6: {list(nf6_node.get('moves', {}).keys())}")
            else:
                 print("ERROR: 'Nf6' missing after 'd4'.")
        else:
            print("ERROR: 'd4' missing from root moves.")
            
        # Verify stats
        print(f"Root Stats: {data.get('stats')}")

    except Course.DoesNotExist:
        print("Error: Course 'The Modern Benoni' not found.")
    except Exception as e:
        print(f"An error occurred: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_generate_tree_with_benoni()



















