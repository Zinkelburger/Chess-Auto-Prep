#!/usr/bin/env python3
"""
Game lookup URLs for chessgames.com browser search.
Prints the search URL for each unmatched game.
Run manually in a browser or feed to the browser tool.
"""

GAMES = [
    {"white": "Kramnik", "black": "Topalov", "year": "1999", "eco": "A40"},
    {"white": "Vaganian", "black": "Khalifman", "year": "1996", "eco": "D76"},
    {"white": "Pigusov", "black": "Ye Jiangchuan", "year": "1993", "eco": "D76"},
    {"white": "Ippolito", "black": "Nakamura", "year": "2003", "eco": "D76"},
    {"white": "Ippolito", "black": "Evdokimov", "year": "2012", "eco": "D76"},
    {"white": "Wojtkiewicz", "black": "Yanayt", "year": "2004", "eco": "D75"},
    {"white": "Tomashevsky", "black": "Mamedyarov", "year": "2009", "eco": "D75"},
    {"white": "Kotsur", "black": "Rakhmanov", "year": "2008", "eco": "D74"},
    {"white": "Dvoirys", "black": "Berntsen", "year": "2005", "eco": "D74"},
    {"white": "Filippov", "black": "Odeev", "year": "2001", "eco": "D74"},
    {"white": "Ippolito", "black": "Hilton", "year": "2008", "eco": "D78"},
    {"white": "Karpov", "black": "Georgiev", "year": "1988", "eco": "D78"},
    {"white": "Khalifman", "black": "Ruck", "year": "1996", "eco": "D78"},
    {"white": "Romanishin", "black": "Gulko", "year": "1991", "eco": "D78"},
    {"white": "Wojtkiewicz", "black": "Mohring", "year": "1988", "eco": "D78"},
    {"white": "Tregubov", "black": "Bezemer", "year": "2004", "eco": "D78"},
    {"white": "Melkumyan", "black": "Kozul", "year": "2012", "eco": "D78"},
    {"white": "Ivanchuk", "black": "Leko", "year": "1995", "eco": "D73"},
    {"white": "Lerner", "black": "Serebro", "year": "2002", "eco": "D73"},
    {"white": "Wojtkiewicz", "black": "Sasikiran", "year": "1999", "eco": "D73"},
    {"white": "Wojtkiewicz", "black": "Boudreaux", "year": "2005", "eco": "B38"},
    {"white": "Wojtkiewicz", "black": "Whaley", "year": "2006", "eco": "B39"},
    {"white": "Vitiugov", "black": "Sedlak", "year": "2012", "eco": "B36"},
    {"white": "Goloshchapov", "black": "Wirig", "year": "2004", "eco": "B36"},
    {"white": "Wojtkiewicz", "black": "Langenberg", "year": "1996", "eco": "A39"},
    {"white": "Hilton", "black": "Hanken", "year": "2006", "eco": "A30"},
    {"white": "Hilton", "black": "Sprague", "year": "2008", "eco": "A39"},
    {"white": "Hilton", "black": "Whorton", "year": "2007", "eco": "A39"},
    {"white": "Hilton", "black": "Casden", "year": "2009", "eco": "A39"},
    {"white": "Hilton", "black": "Dennis", "year": "2008", "eco": "A39"},
    {"white": "Wojtkiewicz", "black": "La Flair", "year": "1993", "eco": "A39"},
    {"white": "Kasparov", "black": "Uko", "year": "1994", "eco": "A38"},
    {"white": "Lenderman", "black": "Kudrin", "year": "2010", "eco": "A33"},
    {"white": "Wojtkiewicz", "black": "Shahade", "year": "2002", "eco": "A33"},
    {"white": "Miton", "black": "Bocharov", "year": "2007", "eco": "A33"},
    {"white": "Hilton", "black": "Michaelides", "year": "2009", "eco": "A30"},
    {"white": "Hilton", "black": "Sadvakasov", "year": "2007", "eco": "A30"},
    {"white": "Pigusov", "black": "Yudasin", "year": "1990", "eco": "A34"},
    {"white": "Bauer", "black": "Riva Aguado", "year": "2001", "eco": "A81"},
    {"white": "Wojtkiewicz", "black": "Santos", "year": "2004", "eco": "A87"},
    {"white": "Salem", "black": "Gleizerov", "year": "2011", "eco": "A90"},
    {"white": "Spyrou", "black": "Limbourg", "year": "2007", "eco": "A84"},
    {"white": "Miles", "black": "Roos", "year": "1981", "eco": "A99"},
    {"white": "Hilton", "black": "Burgess", "year": "2009", "eco": "A55"},
    {"white": "Arnason", "black": "Angelis", "year": "1993", "eco": "A13"},
    {"white": "Wojtkiewicz", "black": "Hilton", "year": "2005", "eco": "D76"},
]

if __name__ == '__main__':
    for i, g in enumerate(GAMES):
        url = (
            f"https://www.chessgames.com/perl/chess.pl?"
            f"player={g['white']}&player2={g['black']}"
            f"&yearcomp=exactly&year={g['year']}"
        )
        print(f"[{i+1}] {g['white']} vs {g['black']} ({g['year']}) [{g['eco']}]")
        print(f"    {url}")
