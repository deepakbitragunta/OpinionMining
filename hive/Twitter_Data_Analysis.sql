-- Using existing jar file for the row parsing
ADD JAR json-serde-1.1.6-SNAPSHOT-jar-with-dependencies.jar;


-- Using online English dictionary
CREATE EXTERNAL TABLE english_dictionary (
    type string,
    length int,
    word string,
    pos string,
    polarity string
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t' 
STORED AS TEXTFILE
LOCATION '/user/deepak/data/dictionary';

--Using the time zone data available
CREATE EXTERNAL TABLE time_zone_map (
    time_zone string,
    country string,
    notes string
)
ROW FORMAT DELIMITED FIELDS TERMINATED BY '\t' 
STORED AS TEXTFILE
LOCATION '/user/deepak/data/time_zone_map';


--create the tweet_data table containing the records as received from Twitter

CREATE EXTERNAL TABLE tweet_data (
   id BIGINT,
   created_at STRING,
   source STRING,
   favorited BOOLEAN,
   retweet_count INT,
   text STRING,
   user STRUCT<
      screen_name:STRING,
      name:STRING,
      friends_count:INT,
      followers_count:INT,
      statuses_count:INT,
      verified:BOOLEAN,
      utc_offset:STRING, -- was INT but nulls are strings
      time_zone:STRING>
)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION '/user/deepak/data/tweet_data'
;	

-- Format the raw tweets by extracting the tweet text and timestamps from the tweets
CREATE VIEW tweets_simple AS
SELECT
  id,
  cast ( from_unixtime( unix_timestamp(concat( '2014 ', substring(created_at,5,15)), 'yyyy MMM dd hh:mm:ss')) as timestamp) ts,
  text,
  user.time_zone 
FROM tweet_data
;

-- Clean the tweets_simple table and join them with the time zone map. Put the join result into tweets_join_timezone
CREATE VIEW tweets_join_timezone AS
SELECT
  id,
  ts,
  text,
  m.country 
 FROM tweets_simple t LEFT OUTER JOIN time_zone_map m ON t.time_zone = m.time_zone;

-- Now apply the original algorithm by partitioning the text into words and put the data into view.
create view tweets_words as select id, words from tweet_data lateral view explode(sentences(lower(text))) dummy as words;

--Now check for each word and put them into new view
create view tweets_words_original as select id, word from tweets_words lateral view explode( words ) dummy as word ;

-- Calculate the polarity of each word and assign a number from {-1,1,0} to each word
-- Now, put the result into tweet_polarity table

create view tweet_polarity as select 
    id, 
    tweets_words_original.word, 
    case d.polarity 
      when  'negative' then -1
      when 'positive' then 1 
      else 0 end as polarity 
 from tweets_words_original left outer join english_dictionary d on tweets_words_original.word = d.word;
 
 -- Now tweets_opinion table created with the sum of each polarity of words in a sentence and grouped them by id.
 create table tweets_opinion stored as orc as select 
  id, 
  case 
    when sum( polarity ) > 0 then 'positive' 
    when sum( polarity ) < 0 then 'negative'  
    else 'neutral' end as opinion 
 from tweet_polarity group by id;

-- Now, the final output table tweetopinion is created with the final count of polarity
-- Categorize them based on the country by using the left outer join operation
-- Now, this is the final output table which will be exported into Microsoft Excel

CREATE TABLE tweetopinion 
STORED AS ORC
AS
SELECT 
  t.* 
FROM tweets_join_timezone z LEFT OUTER JOIN tweets_opinion t  on z.id = t.id;