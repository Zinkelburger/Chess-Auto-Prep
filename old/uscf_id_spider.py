import scrapy
from scrapy.crawler import CrawlerProcess

class UscfIDSpider(scrapy.Spider):
    name = 'chess_search'
    allowed_domains = ['uschess.org']
    start_urls = ['https://www.uschess.org/msa/thin2.php']

    custom_settings = {
        'USER_AGENT': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.105 Safari/537.36'
    }

    def __init__(self, first_name='', last_name='', *args, **kwargs):
        super(UscfIDSpider, self).__init__(*args, **kwargs)
        self.first_name = first_name
        self.last_name = last_name

    def start_requests(self):
        formdata = {'memfn': self.first_name, 'memln': self.last_name, 'mode': 'Search'}
        yield scrapy.FormRequest(url=self.start_urls[0], formdata=formdata, callback=self.parse)

    def parse(self, response):
        # Extracting rows that contain the search results
        rows = response.xpath('//table//tr[td and not(td[@colspan])]')  # Exclude rows without <td> or with <td colspan=...>
        for row in rows:
            yield {
                'id': row.xpath('.//td[1]/text()').get(),
                'name': row.xpath('.//td[2]/text()').get(),
                'details': row.xpath('.//td[3]/text()').get(),
                'status': row.xpath('.//td[4]/font/text()').get(default='Active')  # Default to 'Active' if no status found
            }

def uscf_id_spider(first_name, last_name):
    process = CrawlerProcess(settings={
        'FEED_FORMAT': 'json',
        'FEED_URI': 'uscf_output.json'
    })
    process.crawl(UscfIDSpider, first_name=first_name, last_name=last_name)
    process.start()

# uscf_id_spider('Michael', 'Carter')
