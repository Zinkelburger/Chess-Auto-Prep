
from django.db import models
from django.conf import settings
from django.core.validators import FileExtensionValidator
import chess.pgn
import json
import gzip
from django.core.files.base import ContentFile
import io
import os

class Course(models.Model):
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    author = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    
    pgn_file = models.FileField(
        upload_to='courses/pgns/',
        validators=[FileExtensionValidator(allowed_extensions=['pgn'])]
    )
    
    # The generated JSON tree for the website to display
    tree_json_file = models.FileField(upload_to='courses/trees/', blank=True, null=True)
    
    is_moderator_approved = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.title

    def save(self, *args, **kwargs):
        # If this is a new course or PGN changed, generate the tree
        is_new = self.pk is None
        # TODO: check if file changed on update
        
        super().save(*args, **kwargs)
        
        if is_new and self.pgn_file:
            self.generate_tree()

    def generate_tree(self):
        """
        Parses the PGN file and generates a JSON tree structure.
        """
        try:
            pgn_path = self.pgn_file.path
            # Standard starting position FEN (without move counts)
            initial_fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
            clean_initial_fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -'
            
            tree = {
                'fen': clean_initial_fen, 
                'moves': {}
            }
            
            with open(pgn_path, 'r', encoding='utf-8', errors='ignore') as pgn:
                while True:
                    try:
                        game = chess.pgn.read_game(pgn)
                    except Exception:
                        break
                        
                    if game is None:
                        break
                        
                    # Always start board from standard initial position 
                    board = chess.Board() 
                    current_node = tree
                    
                    for move in game.mainline_moves():
                        san = board.san(move)
                        board.push(move)
                        fen = board.fen()
                        # Strip move clocks for better aggregation
                        fen_parts = fen.split(' ')
                        clean_fen = ' '.join(fen_parts[:4])
                        
                        if san not in current_node['moves']:
                            current_node['moves'][san] = {
                                'fen': clean_fen,
                                'moves': {}
                            }
                        
                        current_node = current_node['moves'][san]

            # Save as compressed JSON
            json_str = json.dumps(tree)
            # self.tree_json_file.save(f'{self.id}_tree.json', ContentFile(json_str), save=True) # Non-compressed for now for easier debugging
            
            # For production we'd use gzip, but for now let's just save plain JSON
            self.tree_json_file.save(f'{self.id}_tree.json', ContentFile(json_str), save=True)
            
        except Exception as e:
            print(f"Error generating tree for course {self.id}: {e}")

class Review(models.Model):
    course = models.ForeignKey(Course, related_name='reviews', on_delete=models.CASCADE)
    author = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    rating = models.IntegerField(choices=[(i, i) for i in range(1, 6)])
    text = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)
    
    def __str__(self):
        return f"{self.course.title} - {self.rating}/5"
