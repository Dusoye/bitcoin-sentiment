library(dplyr)
library(ggplot2)
library(stringr)
library(data.table)
library(purrr)
library(tibble)

library(xts)
library(zoo)
library(quantmod)

library(rtweet)
library(ROAuth)
library(tidytext)

options(digits.secs=3)

#############################
## twitter connection details
#############################

source("twitterkey.R") # Twitter api access credentials 

create_token(
  consumer_key = consumer_key,
  consumer_secret = consumer_secret,
  access_token = access_token,
  access_secret = access_secret
  )

#############################
## historic btc prices
#############################

download.file('https://api.bitcoincharts.com/v1/csv/coinbaseUSD.csv.gz',temp)
#temp <- 'coinbaseUSD.csv.gz'
btc.prices <- read.csv(gzfile(temp),header=FALSE)
names(btc.prices) <- c('timestamp','price','volume')
btc.prices$timestamp <- as.POSIXct(btc.prices$timestamp, origin="1970-01-01")

btc.prices <- filter(btc.prices,timestamp>'2017-01-01')
btc.prices <- xts(btc.prices[,-1], order.by=btc.prices[,1])

btc.daily <- to.daily(btc.prices)
btc.fivemin <- to.minutes5(btc.prices)
btc.fivemin <- align.time(btc.fivemin,5*60)
tmp <- xts(, seq.POSIXt(start(btc.fivemin), end(btc.fivemin), by="5 mins"))
btc.fivemin <- cbind(tmp, btc.fivemin)

btc.fivemin$returns <- log(btc.fivemin$btc.prices.Close)-log(lag(btc.fivemin$btc.prices.Close,1))

btc.fiveminreturns <- fortify(btc.fivemin) %>% 
  select(timestamp=Index,returns) %>%
  mutate(#returns = if_else(is.na(returns), 0, returns), 
         #returns = if_else(abs(returns) > 1, 0, returns),
         hour_returns = rollapply(returns, 12, sum, fill = 0, align = "left", partial = F))

btc.daily <- to.daily(btc.prices)
btc.daily$returns <- log(btc.daily$btc.prices.Close)-log(lag(btc.daily$btc.prices.Close,1))
btc.dailyreturns <- fortify(btc.daily) %>% 
  select(date = Index, returns) %>%
  mutate(returns = if_else(is.na(returns), 0, returns))

#############################
## extract timelines
#############################

# list of accounts
btc.users <- readLines("https://cryptoweekly.co/100/")
btc.users <- btc.users[grepl('class=\\"author\\"',btc.users)]
btc.users <- sub(".*@ *(.*?) *</a></div>*", "\\1", btc.users)

btc.list <- list()
for(i in btc.users){
  btc.tmp <- get_timelines(i, n=3200, retryonratelimit = TRUE)
  if(length(btc.tmp)==0) next
  btc.list[[i]] <- btc.tmp
}
tweets <- do.call(rbind,btc.list)
rm(btc.list)

tweets %>% select(screen_name) %>% 
  group_by(screen_name) %>% 
  summarise(cnt=n()) %>% 
  arrange(desc(cnt)) %>%
  print(n = nrow(.))

#only btc tweets
search_terms <- c('bitcoin', 'btc', 'crypto', 'blockchain') 
search_terms <- paste(search_terms, collapse = "|")

#############################
## data exploration
#############################

# verified percentage 
tweets %>%
  group_by(screen_name) %>%
  arrange(desc(created_at)) %>%
  slice(1) %>%
  select(screen_name, verified) %>% ungroup() %>%
  group_by(verified) %>%
  summarise(verified_percent = n()) %>% 
  mutate(verified_percent = verified_percent / sum(verified_percent))

# frequence of hashtags
select(tweets, hashtags) %>% 
  unlist(recursive = FALSE) %>% 
  enframe() %>% 
  unnest() %>%
  na.omit(.) %>%
  mutate(value = tolower(value)) %>%
  count(value, sort = TRUE) %>% 
  mutate(value = reorder(value,n)) %>%
  top_n(20) %>%
  ggplot(aes(x = value, y = n)) +
  geom_col() +
  coord_flip() +
  xlab('Hashtag') +
  ylab('Count') +
  ggtitle('Frequency of top hashtags')+
  theme_minimal()

# users who tweet about TRON
tweets %>%
  filter(grepl("#tron|#trx", tolower(text))) %>%
  select(status_id, created_at, screen_name, text) %>%
  group_by(screen_name) %>%
  summarise(tweetcount = n()) %>% 
  mutate(freq = tweetcount / sum(tweetcount)) %>%
  arrange(desc(tweetcount)) %>%
  head(5)
  
# users by location
select(tweets, screen_name, location) %>% 
  distinct(.) %>%
  count(location, sort = TRUE) %>% 
  mutate(location = reorder(location,n)) %>%
  top_n(10) %>% 
  ggplot(aes(x = location, y = n)) +
  geom_col() +
  coord_flip() +
  ylab('User count') +
  ggtitle('Number of users by location')+
  theme_minimal()

# tweets by language         
select(tweets, lang) %>% 
  count(lang, sort = TRUE) %>% 
  mutate(lang = reorder(lang,n)) %>% 
  mutate(n = n/sum(n)) %>%
  top_n(10) %>% 
  ggplot(aes(x = lang, y = n)) +
  geom_col() +
  coord_flip() +
  ylab('Tweet Count') +
  ggtitle('Tweets by language')+
  theme_minimal()

#############################
## sentiment
#############################

## AFINN sentiment from tidytext
tweets %>% select(user_id, status_id, text, created_at) %>% 
  unnest_tokens(word, text) %>%
  inner_join(get_sentiments("afinn"),by="word") %>%
  filter(created_at>='2017-01-01') %>% select(-created_at) %>%
  group_by(user_id, status_id) %>%
  summarise(afinn_sentiment = as.numeric(sum(score))) -> afinn.sentiment

## python pattern sentiment
system('python ./sentiment.py') 
pattern.sentiment <- fread('tweets_sentiment.csv')

pattern.sentiment[!duplicated(pattern.sentiment$id)] %>% 
  mutate(user_id = gsub(", .*$|\\(", "", id),
         status_id = gsub(".*\\, |\\)", "", id),
         sentiment_polarity = as.numeric(gsub(", .*$|\\(", "", sentiment)),
         sentiment_subjectivity = as.numeric(gsub(".*\\, |\\)", "", sentiment))) %>%
  select(-V1, -id, -sentiment) -> pattern.sentiment

# join sentiment calculations to tweets
tweets %>% select(user_id, status_id, screen_name,text,favourites_count,retweet_count,created_at) %>%
  filter(created_at>='2017-01-01') %>%
  merge(., pattern.sentiment, id.vars = c('user_id', 'status_id'), all.x = TRUE) %>%
  merge(., afinn.sentiment, id.vars = c('user_id', 'status_id'), all.x = TRUE) %>%
  mutate_at(vars(contains("sentiment")), ~replace(., is.na(.), 0)) %>%
  arrange(created_at) -> sentiment.tweets

sentiment.tweets %>% 
  mutate(date=as.Date(format(created_at, "%Y-%m-%d")),
         direction=if_else(afinn_sentiment<0,'Negative','Positive')) %>% 
  filter(afinn_sentiment != 0) %>%
  group_by(date, direction) %>%
  summarise(sentiment=sum(afinn_sentiment),
            sentiment_count = n()) %>% 
  mutate(sentiment_count = if_else(direction == 'Negative', -sentiment_count, sentiment_count)) %>%
  ggplot()+
  geom_bar(aes(x=date,y=sentiment_count,fill=direction),stat='identity')+
  ggtitle('AFINN sentiment polarity')+
  theme_minimal()

sentiment.tweets %>% 
  mutate(date=as.Date(format(created_at, "%Y-%m-%d")),
         direction=if_else(afinn_sentiment<0,'Negative','Positive')) %>% 
  filter(afinn_sentiment != 0,
         str_detect(text, regex(search_terms, ignore_case = TRUE))) %>%
  group_by(date, direction) %>%
  summarise(sentiment=sum(afinn_sentiment),
            sentiment_count = n()) %>% 
  mutate(freq = sentiment_count / sum(sentiment_count)) %>% 
  ggplot(aes(x = date, y = freq, fill = direction))+
  geom_bar(stat='identity')+
  ggtitle('AFINN sentiment polarity')+
  theme_minimal() +
  ylab('Frequency %')

sentiment.tweets %>% 
  mutate(date=as.Date(format(created_at, "%Y-%m-%d")),
         direction=if_else(sentiment_polarity<0,'Negative','Positive')) %>% 
  filter(sentiment_polarity != 0,
         str_detect(text, regex(search_terms, ignore_case = TRUE))) %>%
  group_by(date, direction) %>%
  summarise(sentiment=sum(sentiment_polarity),
            sentiment_count = n()) %>% 
  mutate(freq = sentiment_count / sum(sentiment_count)) %>% group_by(direction) %>% #summarise(n=mean(freq))
  ggplot(aes(x = date, y = freq, fill = direction))+
  geom_bar(stat='identity')+
  ggtitle('Pattern sentiment polarity')+
  theme_minimal() +
  ylab('Frequency %')

sentiment.tweets %>%
  mutate(date = as.Date(created_at),
         interactions = favourites_count + retweet_count) %>%
  group_by(date) %>%
  summarise(afinn = sum(afinn_sentiment) / n(),
            pattern = sum(sentiment_polarity) / n(),
            afinn_weighted = sum(afinn_sentiment * interactions) / sum(interactions),
            pattern_weighted = sum(sentiment_polarity * interactions) / sum(interactions)) %>% 
  melt(., id.var = 'date') %>% 
  mutate(model = if_else(substr(variable, 1, 1) == 'a', 'afinn', 'pattern'),
         variable = if_else(grepl('weighted', variable), 'weighted_mean', 'mean')) %>%
  ggplot(aes(x = variable, y = value)) + 
  geom_boxplot(outlier.colour = "red", outlier.shape = 1) + 
  theme_minimal() + 
  facet_grid(model ~ ., scales = "free_y") +
  ylab('Average tweet sentiment by day') + xlab('')
  
sentiment.tweets %>% filter(abs(sentiment_polarity ) > 0.5) %>% 
  mutate(interactions = favourites_count + retweet_count) %>% 
  ggplot(aes(x = sentiment_polarity , y = (interactions))) +
  geom_point() +
  geom_smooth(method = 'lm', formula = y ~ x)
  
#############################
## strategy
#############################

#drawdown function
drawdown <- function(pnl) {
  cum.pnl  <- c(0, cumsum(pnl))
  drawdown <- cum.pnl - cummax(cum.pnl)
  return(tail(drawdown, -1))
}

maxdrawdown <- function(pnl)min(drawdown(pnl))

# create table joining tweet date to bitcoin returns
avginteractions <- median((sentiment.tweets$retweet_count + sentiment.tweets$favourites_count))

# join tweets to price movement
sentiment.tweets %>%
    filter(str_detect(text, regex(search_terms, ignore_case = TRUE))) %>% #only btc/crypto related tweets
    select(user_id, 
           status_id, 
           favourites_count, 
           retweet_count, 
           created_at, 
           pattern_sentiment = sentiment_polarity, 
           afinn_sentiment) %>%
    mutate(timestamp=as.POSIXct(floor(as.numeric(created_at) / (5 * 60)) * (5 * 60), origin='1970-01-01'),
           interactions = (as.numeric(favourites_count + retweet_count))) %>% 
    group_by(timestamp) %>%
    summarise(afinn_weighted = sum(afinn_sentiment * interactions)/avginteractions, 
              pattern_weighted = sum(pattern_sentiment * interactions)/avginteractions,
              afinn_sentiment = sum(afinn_sentiment),
              pattern_sentiment = sum(pattern_sentiment)) %>%
    merge(., btc.fiveminreturns, by = 'timestamp') %>% 
    mutate_at(c(2:7), ~replace(., is.na(.), 0)) -> returns.tweets

returns.tweets %>% 
  mutate(date = as.Date(timestamp)) %>%
  mutate(afinn_returns = if_else(afinn_sentiment > 0, hour_returns,
                                      if_else(afinn_sentiment < 0, -hour_returns, 0)),
         pattern_returns = if_else(pattern_sentiment  > 0, hour_returns,
                                        if_else(pattern_sentiment  < 0, -hour_returns, 0)),
         afinn_weighted_returns = if_else(afinn_weighted > 1, hour_returns,
                                 if_else(afinn_weighted < -1, -hour_returns, 0)),
         pattern_weighted_returns = if_else(pattern_weighted  > 0.1, hour_returns,
                                   if_else(pattern_weighted  < -0.1, -hour_returns, 0))) %>% 
  group_by(date) %>%
  summarise(afinn_returns = sum(afinn_returns),
            pattern_returns = sum(pattern_returns),
            afinn_weighted_returns = sum(afinn_weighted_returns),
            pattern_weighted_returns = sum(pattern_weighted_returns)) %>% 
  merge(., btc.dailyreturns, id = 'date') -> daily.returns

daily.returns %>%  
  mutate(AFINN = cumsum(afinn_returns),
         Pattern = cumsum(pattern_returns),
         'AFINN weighted' = cumsum(afinn_weighted_returns),
         'Pattern weighted' = cumsum(pattern_weighted_returns),
         'Buy and hold' = cumsum(returns)) %>% select(-(matches('returns'))) %>%
  melt(., id.vars = 'date') %>%
  rename(Model = 'variable') %>%
  ggplot(aes(x = date, y = value, colour = Model)) +
  geom_line() +
  theme_minimal() +
  ylab('log returns') +
  ggtitle('Cumulative returns')

daily.returns %>%
  melt(., id.var = 'date') %>%
  mutate(year = year(date)) %>% filter(year != 2019) %>%
  group_by(year, variable) %>%
  summarise('Total returns' = sum(value),
            'Average daily returns' = mean(value),
            'Standard deviation' = sd(value),
            'Maximum drawdown' = maxdrawdown(value)) %>%
  kable(format = 'markdown', digits = 4) 
  #kable_styling(bootstrap_options = c("striped", "hover"))

returns.tweets %>% 
  mutate(date = as.Date(timestamp)) %>%
  mutate(afinn_returns = if_else(afinn_sentiment > 0, returns,
                                 if_else(afinn_sentiment < 0, -returns, 0)),
         pattern_returns = if_else(pattern_sentiment  > 0, returns,
                                   if_else(pattern_sentiment  < 0, -returns, 0)),
         afinn_weighted_returns = if_else(afinn_weighted > 1, returns,
                                          if_else(afinn_weighted < -1, -returns, 0)),
         pattern_weighted_returns = if_else(pattern_weighted  > 0.1, returns,
                                            if_else(pattern_weighted  < -0.1, -returns, 0))) %>% 
  group_by(date) %>%
  summarise(afinn_returns = sum(afinn_returns),
            pattern_returns = sum(pattern_returns),
            afinn_weighted_returns = sum(afinn_weighted_returns),
            pattern_weighted_returns = sum(pattern_weighted_returns)) %>% 
  merge(., btc.dailyreturns, id = 'date') -> fivemin.returns

fivemin.returns %>%  
  mutate(AFINN = cumsum(afinn_returns),
         Pattern = cumsum(pattern_returns),
         'AFINN weighted' = cumsum(afinn_weighted_returns),
         'Pattern weighted' = cumsum(pattern_weighted_returns)) %>% 
  select(-(matches('returns'))) %>%
  melt(., id.vars = 'date') %>%
  rename(Model = 'variable') %>%
  ggplot(aes(x = date, y = value, colour = Model)) +
  geom_line() +
  theme_minimal() +
  ylab('log returns') +
  ggtitle('Cumulative returns')
