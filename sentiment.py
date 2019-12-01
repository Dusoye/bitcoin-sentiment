import pandas as pd
from pattern.en import sentiment

tweets = pd.read_csv('tweets.csv',
                     usecols = ["user_id", "status_id", "created_at", "screen_name", "lang", "text"], 
                     index_col = [0, 1]
                    )

sentiment_df = []
for index, row in tweets.iterrows():
    w = sentiment(row["text"])
    sentiment_df.append([index, w])

sentiment_df = pd.DataFrame(sentiment_df, columns = ["id", "sentiment"])

sentiment_df.to_csv("tweets_sentiment2.csv")
