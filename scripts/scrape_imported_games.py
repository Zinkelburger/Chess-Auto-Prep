import os
import requests
import re
import time
from datetime import datetime
from bs4 import BeautifulSoup

# Configuration
LICHESS_USERNAME = "AltAccount123"
LICHESS_API_TOKEN = os.getenv("LICHESS_API_TOKEN")
BATCH_SIZE = 300

def scrape_imported_game_ids(username, max_games=None):
    """
    Scrape game IDs from the Lichess imported games web page.
    """
    print(f"Scraping imported game IDs for user: {username}...")

    game_ids = []
    page = 1

    while len(game_ids) < (max_games or float('inf')):
        url = f"https://lichess.org/@/{username}/imported"
        if page > 1:
            url += f"?page={page}"

        print(f"Scraping page {page}...")

        try:
            response = requests.get(url)
            response.raise_for_status()

            soup = BeautifulSoup(response.content, 'html.parser')

            # Find all game row overlay links
            game_links = soup.find_all('a', class_='game-row__overlay')

            if not game_links:
                print(f"No more games found on page {page}")
                break

            for link in game_links:
                href = link.get('href')
                if href:
                    # Extract game ID from href like "/Aq9fm8DR" or "/H9rG4JaC/black"
                    game_id = href.split('/')[1].split('/')[0]  # Get first part after /
                    game_ids.append(game_id)

                    if max_games and len(game_ids) >= max_games:
                        break

            print(f"Found {len(game_links)} games on page {page}, total: {len(game_ids)}")
            page += 1

            # Be polite to the server
            time.sleep(1)

        except requests.exceptions.RequestException as e:
            print(f"Error scraping page {page}: {e}")
            break

    print(f"Total game IDs scraped: {len(game_ids)}")
    return game_ids[:max_games] if max_games else game_ids

def download_games_with_evals(game_ids, token, output_file, progress_callback=None):
    """
    Download games by their IDs in batches with evaluations.

    Args:
        game_ids: List of game IDs to download
        token: Lichess API token
        output_file: Output file path
        progress_callback: Optional callback function for progress updates
    """
    if not game_ids:
        if progress_callback:
            progress_callback("No game IDs to download.")
        return

    if progress_callback:
        progress_callback(f"Preparing to download {len(game_ids)} games with evaluations...")

    api_url = "https://lichess.org/games/export/_ids"
    headers = {"Authorization": f"Bearer {token}"}

    # Ensure output directory exists
    os.makedirs(os.path.dirname(output_file), exist_ok=True)

    # Clear the output file
    with open(output_file, "w") as f:
        pass

    # Process games in batches
    total_batches = (len(game_ids) + BATCH_SIZE - 1) // BATCH_SIZE

    for i in range(0, len(game_ids), BATCH_SIZE):
        batch_ids = game_ids[i:i + BATCH_SIZE]
        batch_num = i // BATCH_SIZE + 1

        if progress_callback:
            progress_callback(f"Downloading batch {batch_num}/{total_batches} ({len(batch_ids)} games)...")

        # API expects comma-separated string of IDs
        post_data = ",".join(batch_ids)

        params = {
            "evals": "true",
            "clocks": "true",
            "literate": "true"
        }

        try:
            response = requests.post(api_url, headers=headers, params=params, data=post_data)
            response.raise_for_status()

            # Append to output file
            with open(output_file, "a", encoding="utf-8") as f:
                f.write(response.text)
                f.write("\n\n")

            if progress_callback:
                progress_callback(f"Batch {batch_num}/{total_batches} downloaded successfully")

            # Be polite to the API
            if len(game_ids) > BATCH_SIZE:
                time.sleep(2)

        except requests.exceptions.RequestException as e:
            error_msg = f"Error downloading batch {batch_num}: {e}"
            if progress_callback:
                progress_callback(error_msg)
            raise Exception(error_msg)

    if progress_callback:
        progress_callback(f"Download complete! Games saved to '{output_file}'")

def import_lichess_games_with_evals(username, token, max_games=100, progress_callback=None):
    """
    Main function to import Lichess games with evaluations.

    Args:
        username: Lichess username
        token: Lichess API token
        max_games: Maximum number of games to import
        progress_callback: Optional callback for progress updates

    Returns:
        Path to the output PGN file
    """
    if not token:
        raise ValueError("Lichess API token is required")

    # Generate output filename with timestamp
    timestamp_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_file = f"imported_games/lichess_with_evals_{timestamp_str}.pgn"

    try:
        # Scrape game IDs from web page
        if progress_callback:
            progress_callback(f"Scraping game IDs for user: {username}")

        game_ids = scrape_imported_game_ids(username, max_games)

        if not game_ids:
            raise Exception("No imported game IDs found to download")

        if progress_callback:
            progress_callback(f"Found {len(game_ids)} games to download")

        # Download with evaluations
        download_games_with_evals(game_ids, token, output_file, progress_callback)

        return output_file

    except Exception as e:
        if progress_callback:
            progress_callback(f"Error: {str(e)}")
        raise

def main():
    """Command line interface for testing."""
    max_games = 100
    token = LICHESS_API_TOKEN

    if not token:
        print("Error: Please set the LICHESS_API_TOKEN environment variable.")
        return

    try:
        output_file = import_lichess_games_with_evals(
            LICHESS_USERNAME,
            token,
            max_games,
            progress_callback=print
        )
        print(f"\nSuccess! Games saved to: {output_file}")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()