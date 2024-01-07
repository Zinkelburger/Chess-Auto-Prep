import scrapy
from scrapy.crawler import CrawlerProcess

class ChessMemberDetailsSpider(scrapy.Spider):
    name = 'chess_member_details'
    allowed_domains = ['uschess.org']

    custom_settings = {
        'USER_AGENT': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.105 Safari/537.36'
    }

    def __init__(self, user_id='', *args, **kwargs):
        super(ChessMemberDetailsSpider, self).__init__(*args, **kwargs)
        self.start_urls = [f'https://www.uschess.org/msa/MbrDtlMain.php?{user_id}']

    def parse(self, response):
        ratings = {
            'Online-Regular Rating': self.extract_rating(response, 'Online-Regular Rating'),
            'Online-Quick Rating': self.extract_rating(response, 'Online-Quick Rating'),
            'Online-Blitz Rating': self.extract_rating(response, 'Online-Blitz Rating')
        }
        yield ratings

    def extract_rating(self, response, rating_type):
        return response.xpath(f"//td[contains(text(), '{rating_type}')]/following-sibling::td[1]/b/text()").get(default='Unrated').strip()

def run_spider(user_id):
    process = CrawlerProcess(settings={
        'FEED_FORMAT': 'json',
        'FEED_URI': 'output.json'
    })
    process.crawl(ChessMemberDetailsSpider, user_id=user_id)
    process.start()

# has an online rating:
# run_spider('14647174')
# does not have an online rating:
# run_spider('14647175')
