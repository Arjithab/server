library(textclean)
library(tm)
library(textstem)
library(SnowballC)
library(wordcloud)
library(lsa)
library(cleanNLP)
library(e1071)
library(DMwR)

#Initializing cleanNLP package
cnlp_init_spacy()

#Read the data
data <- read.csv("train.csv")

#Basic Data Cleaning:

#Read the comments
comment_text <- as.character(data$comment_text)

#Removing the white spaces and escape characters
comment_text <- sapply(comment_text, FUN = function(txt) gsub("\\s", " ", txt, fixed = F))

#Converting to lowercase
comment_text <- sapply(comment_text, FUN = tolower)

#Replace contractions
comment_text <- replace_contraction(comment_text, contraction.key = lexicon::key_contractions, ignore.case = TRUE)

#Remove common non-ASCII characters
comment_text <- replace_non_ascii(comment_text, replacement = "", remove.nonconverted = T)

#Replaced numbers with empty strings:
comment_text <- sapply(comment_text, FUN = function(txt) gsub("[0-9]+", "", txt))

#Removing the punctuation
comment_text <- sapply(comment_text, FUN = function(txt) gsub("[[:punct:] ]+", " ", txt))

#Removing the white spaces and escape characters
comment_text <- sapply(comment_text, FUN = function(txt) gsub("\\s+", " ", txt, fixed = F))

#Annotate using clean NLP package:
#Start the timer
start_time <- proc.time()
#Annotate the text comments
annotation_comments <- cnlp_annotate(comment_text)
#End the timer
end_time <- proc.time() - start_time

#Exracting the token:
annotation_comments_token <- annotation_comments$token

#Extracting the words with relevant POS
comments_subset <- annotation_comments_token[annotation_comments_token$upos=="NOUN"|annotation_comments_token$upos=="ADJ"|annotation_comments_token$upos=="ADP"|annotation_comments_token$upos=="ADV"|annotation_comments_token$upos=="INTJ"|annotation_comments_token$upos=="VERB",]

#Start the timer
start_time2 <- proc.time()

#Creating the document vector
doc_vec <- aggregate(comments_subset$word,by=list(comments_subset$id),FUN=function(w) {
  return(paste0(w, collapse = ' '))
})

#End the timer
end_time2 <- proc.time() - start_time2

#Creating the comments vector
comment_pos <- doc_vec$x

#Lemmatization
comment_pos <- lemmatize_strings(comment_pos)

#Removing the stop words (using tm_map library)
comment_pos <- removeWords(comment_pos, stopwords("english"))

#Removing the white spaces and escape characters
comment_pos <- sapply(comment_pos, FUN = function(txt) gsub("\\s+", " ", txt, fixed = F))

#converting comments to corpus:
comment_corpus_pos <- Corpus(VectorSource(comment_pos))

#Converting corpus to dtm:
comment_dtm_pos <- DocumentTermMatrix(comment_corpus_pos)

#Running tf-idf

comment_dtm_pos_tfidf <- DocumentTermMatrix(comment_corpus_pos, control = list(weighting = weightTfIdf))
comment_dtm_pos_tfidf <- removeSparseTerms(comment_dtm_pos_tfidf, 0.999)
#comment_dtm_tfidf

#Word-Cloud with tf-idf:

freq = data.frame(sort(colSums(as.matrix(comment_dtm_pos_tfidf[,1:1000])), decreasing=TRUE))
wordcloud(rownames(freq), freq[,1], max.words=100, colors=brewer.pal(1, "Dark2"))

#Converting DTM to matrix:
design_matrix <- as.matrix(comment_dtm_pos_tfidf)
design_matrix <- as.data.frame(design_matrix)

# Define key to merge on
merge_key <- doc_vec$Group.1

#Adding docID:
design_matrix <- cbind(design_matrix, merge_key)

# Merge DTM with input data to get the output labels
data2 <- data
data2$key <- sapply(rownames(data2), FUN = function(k){
  return(paste0("doc",k))
})

colnames(data2)[3:8] <- c("label_toxic", "label_severe_toxic", "label_obscene", "label_threat", "label_insult", "label_identity_hate")

design_matrix <- merge(design_matrix, data2[, c("label_toxic", "label_severe_toxic", "label_obscene", "label_threat", "label_insult", "label_identity_hate","key")],
                       by.x = "merge_key", by.y = "key", all.x = TRUE)

# bad_label <- design_matrix$label_identity_hate|design_matrix$label_insult|design_matrix$label_obscene|design_matrix$label_severe_toxic|design_matrix$label_threat|design_matrix$label_toxic

# classification model
library(glmnet)
library(irlba)

dmatrix <- design_matrix[, !(colnames(design_matrix) %in% c("label_severe_toxic", "label_obscene", "label_threat", "label_insult", "label_identity_hate","key"))]
dmatrix$label_toxic <- as.factor(dmatrix$label_toxic)

timestamp() #time start
# use irlba to compute singular vectors
dm_svd <- irlba(as.matrix(dmatrix[,-c(1,ncol(dmatrix))]), 200)
timestamp() #time end

# reduce the dimensionality
# dm_svd <- svd(dmatrix[,-c(1,ncol(dmatrix))])

dm_prcomp <-  prcomp_irlba(as.matrix(dmatrix[,-c(1,ncol(dmatrix))]), n=100, scale = F)

# plot the cumulative variance explained
variance_percentage <- dm_svd$d^2/sum(dm_svd$d^2)
variance_percentage <- cumsum(variance_percentage)

plot(variance_percentage, xlim = c(0, 100), type = "b", pch = 16,
     xlab = "principal components", ylab = "cumulative variance explained")

reduced_design_matrix <- as.matrix(dmatrix[,-c(1,ncol(dmatrix))]) %*% as.matrix(dm_svd$v)
reduced_design_matrix <- cbind(as.data.frame(reduced_design_matrix), "label_toxic" = as.factor(design_matrix$label_toxic), "label_severe_toxic" = as.factor(design_matrix$label_severe_toxic), "label_obscene" = as.factor(design_matrix$label_obscene), "label_threat" = as.factor(design_matrix$label_threat), "label_insult" = as.factor(design_matrix$label_insult), "label_identity_hate" = as.factor(design_matrix$label_identity_hate))


# Building the model for label_toxic:
#1. Sampling
#2. Cross Validation and Logistic Regression, XGBoost and Naive Bayes


## User defined functions for modeling

# function to fit models
fit_model <- function(train_data, model_name, max_depth = 6, nround = 100){
  if(model_name == "logistic"){
    print("fitting logistic regression")
    return(glm(Class ~ ., data = train_data, family = "binomial"))
  }
  else if(model_name == "nb"){
    print("fitting naïve bayes")
    return(naiveBayes(Class ~ ., data = train_data))
  }
  else if(model_name == "xgboost"){
    print("fitting xgb")
    params_list <- list(
      max_depth = max_depth,
      eta = 0.3,
      gamma = 0,
      colsample_bytree = 1,
      subsample = 1,
      min_child_weight=1
    )
    xgb_fit <- xgboost(data = as.matrix(train_data[,1:200]),
                       label = as.numeric(train_data$Class)-1,
                       params = params_list, nrounds = nround, verbose = 1,
                       objective = "binary:logistic")
    return(xgb_fit)
  }
}

# function to return predictions on cross validation set

test_predictions <- function(fit, test_fold, model_name){
  if(model_name == "logistic")
    return(as.factor(ifelse(predict(fit, newdata = test_fold)>0.5, 1, 0)))
  else if(model_name == "nb")
    return(predict(fit, test_fold))
  else if(model_name == "xgboost")
    return(as.factor(ifelse(predict(fit, newdata = as.matrix(test_fold[,1:200]))>0.5, 1, 0)))
}

# function to perform 5-fold CV
cross_validate <- function(train_data, folds, model_name, max_depth = 6, nround = 100, metric = "Sensitivity",
                           sampling_method = "downsample"){
  
  # 10-Folds CV
  accuracy <- as.numeric()
  fit_list <- list()
  timestamp() #Start time
  for(i in 1:K){
    print(i)
    # create train folds and resample
    train_fold <- train_data[unlist(folds[-i]),]
    if(sampling_method == "downsample")
      train_fold <- downSample(x = train_fold[,1:200], y = train_fold$Class)
    else if(sampling_method == "smote")
      train_fold <- SMOTE(Class ~ ., data = train_fold)
    
    # create test fold
    test_fold <- train_data[folds[[i]],]
    
    # fit a model
    fit <- fit_model(train_fold, model_name, max_depth, nround)
    fit_list[[i]] <- fit
    
    # calculate evaluation metric
    pred <- test_predictions(fit, test_fold, model_name)
    confusion_matrix <- confusionMatrix(data = pred, test_fold$Class, positive = "1")
    accuracy <- c(accuracy, confusion_matrix$byClass[[metric]])
  }
  timestamp() #End time
  return(list(accuracy, fit_list))
}

# Model for label $toxic$

train_toxic <- cbind(as.data.frame(reduced_design_matrix[,1:200]), "Class" = as.factor(reduced_design_matrix$label_toxic))

# create folds
set.seed(1)
K <- 5
folds <- createFolds(train_toxic$Class, k = K)

# fit logistic regression model
result_logistic <- cross_validate(train_toxic, folds, model_name = "logistic", metric = "F1")
metric_logistic <- result_logistic[[1]]
fits_logistic <- result_logistic[[2]]
best_fit_logistic <- fits_logistic[[which.max(metric_logistic)]]

# fit naive bayes model
result_nb <- cross_validate(train_toxic, folds, model_name = "nb", metric = "F1")
metric_nb <- result_nb[[1]]
fits_nb <- result_nb[[2]]
best_fit_nb <- fits_logistic[[which.max(metric_nb)]]

# fit gradient boosted trees
metric_xgb <- c()
fits_xgb <- c()
i <- 1
for(nround in c(50, 75, 100)){
  for(max_depth in c(4,6,8)){
    result <- cross_validate(train_toxic, folds, model_name = "xgboost", metric = "F1",
                             max_depth = max_depth, nround = nround)
    print(result[[1]])
    metric_xgb <- c(metric_xgb, max(result[[1]]))
    fits_xgb[[i]] <- result[[2]][[which.max(result[[1]])]]
    i <- i+1
  }
}
best_fit_xgb <- fits_logistic[[which.max(metric_xgb)]]

# Model for label $threat$

train_threat <- cbind(as.data.frame(reduced_design_matrix[,1:200]), "Class" = as.factor(reduced_design_matrix$label_threat))

# create folds
set.seed(1)
K <- 5
folds <- createFolds(train_threat$Class, k = K)

# fit logistic regression model
result_logistic <- cross_validate(train_threat, folds, model_name = "logistic",
                                  metric = "F1", sampling_method = "smote")
metric_logistic <- result_logistic[[1]]
fits_logistic <- result_logistic[[2]]
best_fit_logistic <- fits_logistic[[which.max(metric_logistic)]]

# fit naive bayes model
result_nb <- cross_validate(train_threat, folds, model_name = "nb", metric = "F1", sampling_method = "smote")
metric_nb <- result_nb[[1]]
fits_nb <- result_nb[[2]]
best_fit_nb <- fits_nb[[which.max(metric_nb)]]

# fit gradient boosted trees
metric_xgb <- c()
fits_xgb <- c()
i <- 1
for(nround in c(50, 75, 100)){
  for(max_depth in c(4,6,8)){
    result <- cross_validate(train_threat, folds, model_name = "xgboost", metric = "F1",
                             max_depth = max_depth, nround = nround, sampling_method = "smote")
    print(result[[1]])
    metric_xgb <- c(metric_xgb, max(result[[1]]))
    fits_xgb[[i]] <- result[[2]][[which.max(result[[1]])]]
    i <- i+1
  }
}
best_fit_xgb <- fits_xgb[[which.max(metric_xgb)]]

# Model for label $insult$

train_insult <- cbind(as.data.frame(reduced_design_matrix[,1:200]), "Class" = as.factor(reduced_design_matrix$label_insult))

# create folds
set.seed(1)
K <- 5
folds <- createFolds(train_insult$Class, k = K)

# fit logistic regression model
result_logistic <- cross_validate(train_insult, folds, model_name = "logistic",
                                  metric = "F1", sampling_method = "downsample")
metric_logistic <- result_logistic[[1]]
fits_logistic <- result_logistic[[2]]
best_fit_logistic <- fits_logistic[[which.max(metric_logistic)]]
save(best_fit_logistic, file = "logistic_insult.rda")
save(metric_logistic, file = "metric_logistic_insult.rda")

# fit naive bayes model
result_nb <- cross_validate(train_insult, folds, model_name = "nb", metric = "F1", sampling_method = "downsample")
metric_nb <- result_nb[[1]]
fits_nb <- result_nb[[2]]
best_fit_nb <- fits_nb[[which.max(metric_nb)]]
save(best_fit_nb, file = "nb_insult.rda")
save(metric_nb, file = "metric_nb_insult.rda")

# fit gradient boosted trees
metric_xgb <- c()
fits_xgb <- c()
i <- 1
for(nround in c(50, 75, 100)){
  for(max_depth in c(4,6,8)){
    result <- cross_validate(train_insult, folds, model_name = "xgboost", metric = "F1",
                             max_depth = max_depth, nround = nround, sampling_method = "downsample")
    print(result[[1]])
    metric_xgb <- c(metric_xgb, max(result[[1]]))
    fits_xgb[[i]] <- result[[2]][[which.max(result[[1]])]]
    i <- i+1
  }
}
best_fit_xgb <- fits_xgb[[which.max(metric_xgb)]]


# Model for label $ihate$

train_ihate <- cbind(as.data.frame(reduced_design_matrix[,1:200]), "Class" = as.factor(reduced_design_matrix$label_identity_hate))

# create folds
set.seed(1)
K <- 5
folds <- createFolds(train_ihate$Class, k = K)

# fit logistic regression model
result_logistic <- cross_validate(train_ihate, folds, model_name = "logistic",
                                  metric = "F1", sampling_method = "downsample")
metric_logistic <- result_logistic[[1]]
fits_logistic <- result_logistic[[2]]
best_fit_logistic <- fits_logistic[[which.max(metric_logistic)]]

# fit naive bayes model
result_nb <- cross_validate(train_ihate, folds, model_name = "nb", metric = "F1", sampling_method = "downsample")
metric_nb <- result_nb[[1]]
fits_nb <- result_nb[[2]]
best_fit_nb <- fits_nb[[which.max(metric_nb)]]

# fit gradient boosted trees
metric_xgb <- c()
fits_xgb <- c()
i <- 1
for(nround in c(50, 75, 100)){
  for(max_depth in c(4,6,8)){
    result <- cross_validate(train_ihate, folds, model_name = "xgboost", metric = "F1",
                             max_depth = max_depth, nround = nround, sampling_method = "downsample")
    print(result[[1]])
    metric_xgb <- c(metric_xgb, max(result[[1]]))
    fits_xgb[[i]] <- result[[2]][[which.max(result[[1]])]]
    i <- i+1
  }
}
best_fit_xgb <- fits_xgb[[which.max(metric_xgb)]]
