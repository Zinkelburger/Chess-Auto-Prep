`pip3 install scrapy`
`pip3 install python-chess`
`pip3 install python-dotenv`
# 1. Given name, go on USCF website
check if they have played in online events

https://chess.stackexchange.com/questions/1295/is-there-a-uscf-api


# Consider only games played in the last month. Then can look at last 2 months, etc. Do not consider bullet games.

- Unable to google search, automated searching goes against their terms of service

- Unable to browse chess.com, against their TOS

- Google Programmmable Search Engine "Custom Search JSON API"

- USCF web scraping gives: ID, Name, State, expiration date of membership, rating


# 1. Get USCF ID
# 2. Check if they have played online events
# 3. If they have, identify the event & get their username
# 4. 

-  run each spider in a separate process

