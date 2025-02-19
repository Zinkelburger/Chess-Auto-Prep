import os
import time
import requests
from typing import Dict, Tuple, List, Optional
from dotenv import load_dotenv

load_dotenv()  # read .env file for LICHESS token, if present
LICHESS_TOKEN = os.getenv("LICHESS")  # e.g. "lalala" if .env says LICHESS=lalala

class FenDatabaseMap:
    """
    A helper class that queries the Lichess Opening Explorer at
    https://explorer.lichess.ovh/lichess for each FEN
    and stores aggregated stats (white wins, black wins, draws).
    """
    def __init__(self, lichess_token: Optional[str] = None):
        # fen -> (white_wins, draws, black_wins, total_games)
        self.lichess_map: Dict[str, Tuple[int, int, int, int]] = {}
        self.lichess_token = lichess_token

    def query_lichess_for_fens(
        self,
        fen_list: List[str],
        output_filename: str,
        speeds: List[str] = None,
        ratings: List[str] = None,
        delay: float = 0.5
    ) -> None:
        """
        Query the new Lichess Opening Explorer endpoint for each FEN in fen_list.
        Store the aggregated stats in self.lichess_map,
        and write results to output_filename.

        :param fen_list: list of FEN strings
        :param output_filename: path for CSV file to write
        :param speeds: e.g. ["blitz", "rapid", "classical"]
        :param ratings: e.g. ["2000", "2200", "2500"]
        :param delay: seconds to wait between each query to avoid rate-limiting
        """
        if speeds is None:
            speeds = ["blitz", "rapid", "classical"]  # some default speeds
        if ratings is None:
            ratings = ["2000", "2200", "2500"]        # some default rating buckets

        # Convert lists into comma-separated strings
        speeds_str = ",".join(speeds)
        ratings_str = ",".join(ratings)

        with open(output_filename, "w", encoding="utf-8") as out_file:
            # Write a header line
            out_file.write("FEN,Lichess White,Lichess Draw,Lichess Black,TotalGames\n")

            for i, fen in enumerate(fen_list):
                stats = self._query_lichess_explorer_for_position(fen, speeds_str, ratings_str)
                
                if stats is not None:
                    white_count, draw_count, black_count = stats
                    total_games = white_count + draw_count + black_count
                else:
                    white_count, draw_count, black_count, total_games = (0, 0, 0, 0)

                # Store in self.lichess_map
                self.lichess_map[fen] = (white_count, draw_count, black_count, total_games)

                # Write CSV line
                out_file.write(f"\"{fen}\",{white_count},{draw_count},{black_count},{total_games}\n")

                # Be respectful: small delay to avoid hammering the endpoint
                time.sleep(delay)

                # Optionally print progress
                if (i + 1) % 100 == 0:
                    print(f"Queried {i+1}/{len(fen_list)} positions...")

    def _query_lichess_explorer_for_position(
        self,
        fen: str,
        speeds: str,
        ratings: str
    ) -> Optional[Tuple[int, int, int]]:
        """
        Query the Lichess Opening Explorer (https://explorer.lichess.ovh/lichess)
        for a single FEN, returning (white_wins, draws, black_wins).
        If there's no data or an error, return None.
        """
        # Endpoint + query parameters
        url = "https://explorer.lichess.ovh/lichess"
        params = {
            "variant": "standard",
            "fen": fen,
            "speeds": speeds,
            "ratings": ratings,
        }

        # If you want to include your token in the headers:
        headers = {}
        if self.lichess_token:
            headers["Authorization"] = f"Bearer {self.lichess_token}"

        try:
            response = requests.get(url, params=params, headers=headers, timeout=10)

            # If we are rate-limited (429), wait 60 seconds and retry once
            if response.status_code == 429:
                print("Rate limit (429). Pausing for 60 seconds before retrying...")
                time.sleep(60)
                response = requests.get(url, params=params, headers=headers, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                white = data.get("white", 0)
                draws = data.get("draws", 0)
                black = data.get("black", 0)
                return (white, draws, black)
            else:
                print(f"Error: got HTTP {response.status_code} for FEN: {fen}")
                return None

        except requests.exceptions.RequestException as e:
            print(f"Request failed for FEN={fen}, error={e}")
            return None
