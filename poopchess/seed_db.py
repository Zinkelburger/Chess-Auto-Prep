
import os
import sys
import django
from django.core.files import File
from pathlib import Path

# Set up Django environment
sys.path.append(str(Path(__file__).resolve().parent.parent))
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
django.setup()

from core.models import User
from courses.models import Course, Review
from django.contrib.auth import get_user_model

def seed_data():
    User = get_user_model()
    
    # 1. Create Users
    print("Creating users...")
    if not User.objects.filter(username="magnus").exists():
        magnus = User.objects.create_user("magnus", "magnus@chess.com", "password")
    else:
        magnus = User.objects.get(username="magnus")
        
    if not User.objects.filter(username="hikaru").exists():
        hikaru = User.objects.create_user("hikaru", "hikaru@chess.com", "password")
    else:
        hikaru = User.objects.get(username="hikaru")
        
    # 2. Create Course
    print("Creating course...")
    pgn_path = Path("../python/lichess-opening-builder/pgns/benoni.pgn").resolve()
    
    if not pgn_path.exists():
        print(f"Error: PGN file not found at {pgn_path}")
        return

    if not Course.objects.filter(title="The Modern Benoni").exists():
        course = Course(
            title="The Modern Benoni",
            description="A dynamic and unbalanced opening for Black against 1.d4. This course covers the main lines and side variations, perfect for players who want to play for a win.",
            author=magnus,
            is_moderator_approved=True
        )
        
        with open(pgn_path, 'rb') as f:
            course.pgn_file.save('benoni.pgn', File(f), save=True)
            
        print(f"Created course: {course.title}")
    else:
        course = Course.objects.get(title="The Modern Benoni")
        print(f"Course already exists: {course.title}")

    # 3. Create Reviews
    print("Creating reviews...")
    if not Review.objects.filter(course=course, author=hikaru).exists():
        Review.objects.create(
            course=course,
            author=hikaru,
            rating=5,
            text="Excellent course! The lines are very sharp and I've won many games with this."
        )
        print("Created review from Hikaru")

    # Add another review
    if not User.objects.filter(username="random_patzer").exists():
        patzer = User.objects.create_user("random_patzer", "patzer@chess.com", "password")
    else:
        patzer = User.objects.get(username="random_patzer")
        
    if not Review.objects.filter(course=course, author=patzer).exists():
        Review.objects.create(
            course=course,
            author=patzer,
            rating=4,
            text="Good content but a bit too advanced for beginners. Need to know your tactics well."
        )
        print("Created review from Patzer")

if __name__ == "__main__":
    seed_data()








