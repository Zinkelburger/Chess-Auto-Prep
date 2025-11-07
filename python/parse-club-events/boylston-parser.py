import csv
import datetime
import requests
from bs4 import BeautifulSoup

# Base URL for the website
BASE_URL = 'https://boylstonchess.org'

# Set a User-Agent to mimic a browser
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
}

def get_calendar_urls(base_url):
    """
    Generates the calendar URLs for the current month and next month.
    """
    urls = []
    today = datetime.date.today()
    
    # Get current month and year
    month1_name = today.strftime("%B").lower()
    month1_year = today.year
    urls.append(f"{base_url}/calendar/{month1_name}-{month1_year}")
    
    # Get next month and year
    # Go to the 1st of this month, add 32 days to guarantee we are in the next month
    first_day_this_month = today.replace(day=1)
    next_month_date = first_day_this_month + datetime.timedelta(days=32)
    
    month2_name = next_month_date.strftime("%B").lower()
    month2_year = next_month_date.year
    urls.append(f"{base_url}/calendar/{month2_name}-{month2_year}")
    
    return urls

def get_event_links(session, calendar_url, base_url):
    """
    Scrapes a calendar page and returns a set of all event page URLs.
    """
    links_found = set()
    try:
        response = session.get(calendar_url, headers=HEADERS)
        response.raise_for_status()  # Check for HTTP errors
        
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # Find all <a> tags whose href starts with "/events/"
        # This is a broad selector but effective for a calendar
        for link in soup.select('a[href^="/events/"]'):
            href = link.get('href')
            # Filter out the main navigation link "/events"
            if href and href != '/events':
                full_url = base_url + href
                links_found.add(full_url)
                
    except requests.exceptions.RequestException as e:
        print(f"Error fetching calendar {calendar_url}: {e}")
        
    return links_found

def scrape_event_page(session, event_url):
    """
    Scrapes an individual event page for its details.
    """
    try:
        response = session.get(event_url, headers=HEADERS)
        response.raise_for_status()
        
        soup = BeautifulSoup(response.text, 'html.parser')
        
        event_data = {'URL': event_url}
        
        # Get the event title
        title_tag = soup.find('h1')
        event_data['Title'] = title_tag.get_text(strip=True) if title_tag else 'No Title Found'
        
        # Find the <dl> with class "event-info box"
        dl = soup.find('dl', class_='event-info')
        
        details = {}
        description = ""
        if dl:
            # Loop through all <dt> (definition term) tags
            for dt in dl.find_all('dt'):
                key = dt.get_text(strip=True)
                # Find the next <dd> (definition description) tag
                dd = dt.find_next_sibling('dd')
                
                if key and dd:
                    value = dd.get_text(strip=True)
                    details[key] = value
                    if key == 'Description':
                        description = value

        # Populate the data based on user's request
        event_data['Date'] = details.get('Date', 'Not found')
        # Use 'Round Times' as the primary source for Time, fall back to 'Time'
        event_data['Time'] = details.get('Round Times', details.get('Time', 'Not found'))
        event_data['Event Format'] = details.get('Event Format', 'Not found')
        
        # Handle 'Location' intelligently
        location = details.get('Location', 'Not found')
        if location == 'Not found':
            # Check if the event is "Online"
            if 'online' in event_data['Title'].lower() or 'online' in description.lower():
                location = 'Online'
            else:
                # Default to the club's physical address if not specified
                location = '35 Kingston St. Unit 1, Boston, MA 02111'
        
        event_data['Location'] = location
        
        return event_data
        
    except requests.exceptions.RequestException as e:
        print(f"Error scraping event {event_url}: {e}")
        return None

def main():
    # Use a session to keep the connection alive
    with requests.Session() as session:
        all_event_links = set()
        
        calendar_urls = get_calendar_urls(BASE_URL)
        print(f"Fetching calendars for: {', '.join(calendar_urls)}")
        
        for url in calendar_urls:
            print(f"Finding events on: {url}")
            links = get_event_links(session, url, BASE_URL)
            all_event_links.update(links)
            
        if not all_event_links:
            print("No event links found.")
            return

        print(f"\nFound {len(all_event_links)} unique event links. Starting scrape...")
        
        all_event_data = []
        for link in all_event_links:
            print(f"Scraping: {link}")
            data = scrape_event_page(session, link)
            if data:
                all_event_data.append(data)
                
        if not all_event_data:
            print("No event data could be scraped.")
            return
            
        # Write the data to a CSV file
        output_file = 'boylston_chess_events.csv'
        # Define the headers we want in our CSV
        fieldnames = ['Title', 'Date', 'Time', 'Event Format', 'Location', 'URL']
        
        try:
            with open(output_file, 'w', newline='', encoding='utf-8') as f:
                # Use DictWriter to map our dictionaries to CSV rows
                # extrasaction='ignore' will ignore any keys in our dict that
                # are not in the fieldnames list (e.g., 'Description', 'Prizes')
                writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction='ignore')
                writer.writeheader()
                writer.writerows(all_event_data)
                
            print(f"\nSuccess! Saved {len(all_event_data)} events to {output_file}")
            
        except IOError as e:
            print(f"Error writing to CSV file: {e}")

if __name__ == "__main__":
    main()