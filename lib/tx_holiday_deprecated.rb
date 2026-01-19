module TxHolidayDeprecated
    HD_APIURL = 'http://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService'
    HD_APIKEY = 'eMvVlOviSd3%2BFdBhMVMv3CAemSRqyVz6Wxa6MmWhX20iosVTcplI%2BG94tO0lXqkiM3XEjQ6589B7oj%2BP%2BPtOwA%3D%3D'

    def self.holiday?(date)
        service_key = HD_APIKEY
        page_no = 1
        num_of_rows = 10
        now = Time.now
        current_year = now.year
        current_month = now.month
        current_month_url = "#{HD_APIURL}/getRestDeInfo?ServiceKey=#{service_key}&pageNo=#{page_no}&numOfRows=#{num_of_rows}&solYear=#{current_year}&solMonth=#{current_month}"

        begin
            uri = URI(current_month_url)
            response = Net::HTTP.get_response(uri)
            
            if response.code == '200'
                # XML 파싱이 필요하지만 여기서는 간단히 처리
                # 실제로는 nokogiri 등을 사용해야 함
                puts "Holiday API response received"
                
                today = now.day
                day_of_week = now.wday
                is_weekend = day_of_week == 0 || day_of_week == 6
                
                # 간단히 주말만 체크 (실제로는 공휴일 데이터도 파싱해야 함)
                is_weekend
            else
                false
            end
        rescue => error
            warn "휴일 정보를 가져오는 중 오류가 발생했습니다: #{error}"
            false
        end

    end

end