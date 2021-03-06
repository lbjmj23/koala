require 'koala/api/graph_api'
require 'koala/utils'
require 'base64'

module Koala
  module Facebook

    module CountsAPIMethods

      # Return topic counts across API endpoints
      # This method accepts either raw hashtag queries as well as Topic Ids
      # and delegates to proper API endpoint for fetching data
      #
      # @param ids [Array<String>] array of hashtags or Topic Ids (ok to mix)
      # @params opts Hash Options
      # @option opts :mentions_since [Time,Fixnum] Window start (inclusive)
      # @option opts :mentions_until [Time,Fixnum] Window end (inclusive)
      #
      # @return Array<Hash>
      # [
      #   {"query":"#mlb", "name":"#MLB", "count": 123, "breakdown": []},
      #   {"query":"mlb", "name":"MLB", "count": 450,
      #     "breakdown": [{"gender":"male", "count": 101}, {...}]}
      # ]
      #
      def topic_counts(ids, opts={})
        ids = [ids].flatten
        hashtags, topic_ids = ids.partition { |id| Koala::Utils::is_hashtag?(id) }
        hashtag_counts(hashtags, opts) + topic_insights(topic_ids, opts)
      end

      # https://developers.facebook.com/docs/topic_insights
      # Fetch mention counts for a list of topics.
      #
      # Current Facebook API limit of total time frame <= 21600 seconds
      # This method accepts a total time frame that spans greater than API limit
      # and internally chunks api requests using maximum allowed chunk
      # counts are aggregated to the requested time window with respect to both the total
      # and full breakdowns requested
      #
      # @param topic_ids [String, Array<String>] Facebook Topic IDs (use `topic_search`)
      # @param start_time [Time] Window start (inclusive)
      # @param end_time [Time] Window end (exclusive)
      # @param opts Options
      #   @option opts :breakdown_by [Array<String>] Dimensions to break down mention counts by
      # @raise [Koala::Facebook::APIError] if missing topic_id or rate limited
      # @return see `topic_counts`
      #
      def topic_insights(topic_ids, opts={})
        return [] unless (topic_ids && topic_ids.length > 0)
        opts ||= {}
        topic_ids = [topic_ids].flatten

        counts_arr = []

        # keep referance request max time
        until_time = (opts[:mentions_until] || Time.now)
        # TODO max chunk size given current API constraints
        chunk = 21600

        # TODO api docs makes claim that time specified must be on a five minute interval.
        # "For example, you may use 6:00 or 6:05 but not 6:02."
        # however, have not observed this to be true
        # making an idividual request with a time window of less than 5 minutes succeeds

        topic_ids.each do |topic_id|
          # start with request start time
          min_time = (opts[:mentions_since] || (until_time - 3600))
          # initial max time of start + chunk, or full request time window (whichever is smaller)
          max_time = [(min_time + chunk), until_time].min
          # map for aggregating fully broken down counts across request chunks
          breakdown_map = {}

          # url encode each argument as part of query string params
          topics_query_str = "contains_all[]=#{CGI::escape(topic_id)}"

          topic_insight = nil
          # do requests while more chunks
          while min_time < max_time
            # API request parameters
            request_params = {
              "fields" => "topics,mentions"
            }
            # update fields with breakdown_by argument if provided
            if !(opts[:breakdown_by].nil?) && opts[:breakdown_by].length > 0
              request_params["fields"] =
                "#{request_params["fields"]}.breakdown_by(#{opts[:breakdown_by].to_s})"
            end
            # update since and until request parameters
            request_params['fields'] =
              "#{request_params['fields']}.since(#{min_time.to_i.to_s}).until(#{max_time.to_i.to_s})"

            # make request for this chunk of mentions counts
            get_object("topic_insights?#{topics_query_str}", request_params, {}) do |topics_res|
              topics_res.each do |topic_res|
                if topic_res["mentions"] && topic_res["mentions"]["data"]
                  topic_info = (topic_res["topics"] && topic_res["topics"]["data"].first)
                  arr_mentions_data = topic_res["mentions"]["data"]

                  if arr_mentions_data && arr_mentions_data.length > 0
                     # pop the "totals" for the time period
                    chunk_total = arr_mentions_data.shift

                    # add this chunk's total count to totals count
                    topic_insight ||= {
                      "query" => topic_id,
                      "name" => (topic_info && topic_info["name"]).to_s,
                      "count" => 0,
                      "breakdown_by" => []
                    }
                    topic_insight["count"] += (chunk_total && chunk_total['count']).to_i

                    # iterate breakdowns
                    arr_mentions_data.each do |insight|
                      # insight => {"age_range"=>"13-17", "count"=>"180", "gender"=>"male"}
                      # generate a set key composed of all breakdown values that this "count" is grouped by
                      # ex: "13-17|male"
                      breakdown_values = opts[:breakdown_by].map{|k| insight[k]}
                      breakdown_key = Base64.encode64(Marshal.dump(breakdown_values)).chomp
                      # add to existing total for this breakdown grouping
                      breakdown_map[breakdown_key] ||= 0
                      breakdown_map[breakdown_key] += insight["count"].to_i
                    end
                  end
                end
              end
            end

            # update chunking parameters
            min_time = max_time + 1
            max_time = [(min_time + chunk - 1), until_time].min
          end
          # key contains all breakdown vlaues
          # value is the summed count for the requested period
          # each key gets a hash entry in returned structure
          # with each breakdown key/value represented
          # along with our single count for the period
          # breakdown_map entry "13-17|male" becomes:
          # ex: {"age_range" => "13-17", "gender" => "male", count => <sum of chunked counts>}
          breakdown_map.each do |breakdown_key, ct|
            breakdown_entry = {}
            # load breakdown values out of breakdown_key
            breakdown_parts = Marshal.load(Base64.decode64(breakdown_key))
            breakdown_parts.each_with_index do |breakdown_value, idx|
              if breakdown_value.to_s.length > 0
                # set breakdown value for breakdown key for this entry
                # breakdown_entry["gender"] => "male"
                breakdown_entry[opts[:breakdown_by][idx]] = breakdown_value
              end
            end
            # set broken down count aggregated over request time window
            breakdown_entry["count"] = ct
            # add to response structure
            topic_insight["breakdown_by"] << breakdown_entry
          end

          if topic_insight
            counts_arr << topic_insight
          end
        end

        counts_arr
      end

      # https://developers.facebook.com/docs/hashtag_counter
      # Return counts for a list of hashtags within a time window
      #
      # @param hashtags [Array<String>] array of hashtags (with leading '#')
      # @param opts options
      # @options se `topic_counts`
      # @return see `topic_counts`
      #
      def hashtag_counts(hashtags, opts={})
        return [] unless (hashtags && hashtags.length > 0)
        # NOTE: currently not used. offering same api as topic_counts
        opts ||= {}
        hashtags = [hashtags].flatten
        # init a mapping from request argument to a normalized version
        # {"abc": "#Abc"}
        hashtags_args_map = {}
        # map normalized version to original argument
        hashtags.each_with_index do |htag, idx|
          ntag = normalize_hashtag(htag)
          hashtags_args_map[ntag] = htag
          hashtags[idx] = ntag
        end

        # initialize return structure
        # key: hashtag (as requested by caller i.e. "#abc")
        # value: {"name": "#ABC", "count": 123}
        # {"#abc" => {"name": "#ABC", "count": 123}}
        counts_arr = []

        # TODO API enforces times "line up evenly on 300 second intervals"
        # valid: 13:00:00, 13:05:00, 13:10:00, ...
        # do anything to the args?
        start_ts = opts[:mentions_since] && opts[:mentions_since].to_i
        end_ts = opts[:mentions_until] && opts[:mentions_until].to_i

        # NOTE: lib currently encodes array values into comma separated strings
        # however, this api endpoint needs arg "hashtags[]" in url query string
        # including here as part of the path with time args being included in params arg
        # (added to query string by library)
        params = {
          "since" => start_ts.to_s,
          "until" => end_ts.to_s
        }

        # url encode each argument as part of query string params
        hashtags_query_str = hashtags.map do |arg|
          "hashtags[]=#{CGI::escape(arg)}"
        end.join('&')

        # make request for hashtag counts
        # block is called with response object that would have been returned by `get_object` call
        get_object("hashtag_counts?#{hashtags_query_str}", params, {}) do |hashtags_res|
          # iterate response Array
          # [{"count"=>"2147", "hashtag"=>{"id"=>"351255261652168", "name"=>"#MLB"}}, ...]
          hashtags_res.each do |hashtag_doc|
            # get hashtag label as returned by API
            htag_name = (hashtag_doc['hashtag'] && hashtag_doc['hashtag']['name']).to_s
            # normalize returned hashtag and map it back to requested hashtag
            htag = hashtags_args_map[normalize_hashtag(htag_name)]
            # add to return structure
            counts_arr << {
              "query" => htag,
              "name" => htag_name,
              "count" => hashtag_doc['count'].to_i,
              "breakdown_by" => []
            }
            # entity_id = (hashtag_doc['hashtag'] && hashtag_doc['hashtag']['id']).to_s
            # if entity_id.length > 0
            #   doc["id"] = Base64.encode64("topic_#{entity_id}").chomp
            # end
          end
        end

        counts_arr
      end

      private

      # to lower case, remove 1 leading '#'
      def normalize_hashtag(htag)
        strip_leading_tag(htag).downcase
      end

      def strip_leading_tag(htag)
        htag.gsub(/^\#{1}/,'')
      end

    end

  end
end
