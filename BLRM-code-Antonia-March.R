library(tidyverse)
library(rjags)
library(runjags)
library(purrr)
library(dplyr)
library("xtable")


#dose levels 
doses <- c(20,40,80,160,320,640,960)
#number of patients per current dose(MONO)
n.patients.per.dose.MONO <- c(0,0,2,3,0,0,0)
#number of patients per current dose (COMBO)
n.patients.per.dose.COMBO <- c(0,0,0,0,0,0,0)
#total number of patients across all dose levels
N <- sum(n.patients.per.dose.MONO + n.patients.per.dose.COMBO) 
#whether a patient had a DLT or not 
s <- c(0,0,0,0,0)
#current dose for each patient
d <- c(80,80,160,160, 160)#c(rep(doses, 2))
#reference dose
D.ref <- 960
#binary indicator I (0=monotherapy, 1 = combination therapy)
I.combo <- c(0,0,0,0,0)
#I.combo <- c(rep(0, length(doses)), rep(1, length(doses)))

#vector of prior means 
mu0 <- -1.75
mu1 <- 0.00
mu2 <- 0.00
priorMean <- c(mu0, mu1, mu2)

#covariance matrix
sigma0 <- 1.60
sigma1 <- 0.2
sigma2 <- 1.5
priorVar <- matrix(c(sigma0^2, 0, 0,
                     0, sigma1^2, 0,
                     0, 0, sigma2^2), ncol = 3, byrow = TRUE)

priorPrec <- solve(priorVar)

#iterations
n.chains <- 3
iter.per.chain <- 1e6
burn.in <- 1e4
total.iter <- iter.per.chain + burn.in
#overdose probability threshold
c.overdose<-0.40 
#number of DLTs on the current dose levels per each patient 
no.DLT = c(0,0,0,0,0)

#####


############################################################################################################

blrm.data <- list(
  D.ref = D.ref,
  s = s,
  d = d,
  N = N,
  priorPrec = priorPrec,
  I.combo = I.combo,
  priorMean = priorMean
)


# Model specification for JAGS
blrm.model.string <- "
model {
  ## Priors ##
  theta[1:3] ~ dmnorm(priorMean[], priorPrec[1:3,1:3])

  
  alpha0 <- theta[1]
  alpha1 <- exp(theta[2])
  alpha2 <- exp(theta[3])

  ## Likelihood ##
  for (j in 1:N) {
    lin.pred.p.1[j] <- alpha0 + alpha1 * log(d[j]/D.ref) + alpha2 * I.combo[j]
    lin.pred.p.2[j] <- ifelse(lin.pred.p.1[j] < -10, -10, ifelse(lin.pred.p.1[j] > 10, 10, lin.pred.p.1[j]))
    p[j] <- exp(lin.pred.p.2[j]) / (1 + exp(lin.pred.p.2[j])) 
    s[j] ~ dbern(p[j])
    
  }
}
"

blrm.model <- jags.model(textConnection(blrm.model.string), data = blrm.data, n.chains = n.chains)
update(blrm.model, iter = burn.in)
samples <- jags.samples(blrm.model, 
                        variable.names = c("alpha0", "alpha1", "alpha2"), 
                        n.iter = iter.per.chain,
                        thin = 1)

# Extract posterior samples
a01 <- samples$alpha0[1, ,]
a11 <- samples$alpha1[1, , ]
a21 <- samples$alpha2[1, , ]

mean(a01)
mean(a11)
mean(a21)
########################################
#create empty vectors to store estimates 
LCI<-UCI<-Pi.MTD<-Pi.MTD.store<-Pi.above<-toxicity<-mat.or.vec(length(doses)*2,1)
all.Pi <-mat.or.vec(iter.per.chain * n.chains,length(doses)*2)
allstop <-0

d <- c(rep(doses, 2))


#reference dose
D.ref <- 960
#binary indicator I (0=monotherapy, 1 = combination therapy)
I.combo <- c(rep(0, length(doses)), rep(1, length(doses)))
s <- rep(0, length(doses)*2)


for (j in 1:(length(doses)*2)) {
  LP <- a01 + a11 * log(d[j]/D.ref) + a21 * I.combo[j]
  #make sure LP stays between -10 and 10
  LP <- pmin(pmax(LP, -10), 10)
  #calculate the odds
  odds <- exp(LP)
  #calculate the predicted probabilities for specific j
  Pi <- odds / (1 + odds)
  #calculate Pi for DLT for individual patient j at their current dose level
  Pi.MTD.store[j] <- Pi.MTD[j] <- mean(Pi < 0.30) - mean(Pi < 0.20)
  #probability of toxicity greater than 30%
  Pi.above[j] <- mean(Pi > 0.30)
  #average predicted probability of toxicity across all patients j
  toxicity[j] <- mean(Pi)
  #Lower CI
  LCI[j] <- quantile(Pi, 0.025)
  #Upper CI
  UCI[j] <- quantile(Pi, 0.975)
}

Pi.MTD[Pi.MTD == 0] <- 0.001
Pi.MTD[Pi.above > c.overdose] <- 0

#create empty vectors to store new variables for MONO
Pi.MTD.mono <- Pi.MTD[1:length(doses)]
Pi.MTD.mono.store <- Pi.MTD.store[1:length(doses)]
Pi.above.mono <- Pi.above[1:length(doses)]
toxicity.mono <- toxicity[1:length(doses)]
n.mono <- n.patients.per.dose.MONO[1:length(doses)]
s.mono <- s[1:length(doses)]
LCI.mono <- LCI[1:length(doses)]
UCI.mono <- UCI[1:length(doses)]

###

# vectors for COMBO
Pi.MTD.combo <- Pi.MTD[(length(doses)+1):(2*length(doses))]
Pi.MTD.combo.store<-Pi.MTD.store[(length(doses)+1):(2*length(doses))]
Pi.above.combo<-Pi.above[(length(doses)+1):(2*length(doses))]
toxicity.combo<-toxicity[(length(doses)+1):(2*length(doses))]
n.combo<- n.patients.per.dose.COMBO[1:length(doses)]
s.combo<-s[(length(doses)+1):(2*length(doses))]
LCI.combo<-LCI[(length(doses)+1):(2*length(doses))]
UCI.combo<-UCI[(length(doses)+1):(2*length(doses))]


###############################################################
coherence.up = T
prediction = FALSE
current.dose <- 4

# Decision logic based on MTD probabilities and overdose probabilities
if(all(Pi.MTD==0)){
  # If no dose levels are considered admissible for both mono and combo therapy, set stop to 1 and reset the next dose and admissible doses variables to 0
  stop <- 1
  next.dose.mono <- next.dose.combo <- 0
  admissible.doses.mono <- admissible.doses.combo <- c(0)
} else {
  
  if(sum(s.mono)>0) {
    increment<-2
  }else{
    increment<-3
  }
  
  ##coherence constraint
  if(all((no.DLT/N)>=1/3 & coherence.up)){
    index <- which(doses>doses[current.dose])
    Pi.MTD.mono[index]<-0
  }else{
    #no dose skip                            ##NB! it doesn't work for mono 
    if(current.dose<(length(doses)-1)){
      index <-(current.dose+2):length(doses)
      Pi.MTD.mono[index]<-0
    }
  }
  
  admissible.doses.mono<-which(Pi.MTD.mono>0,arr=T)
  next.dose.mono <- which.max(Pi.MTD.mono)
  
  if(all(Pi.MTD.mono==0)){
    admissible.doses.mono<-next.dose<-0
  }
  ###combo
  index.1<-which(Pi.MTD.mono==0)
  Pi.MTD.combo[index.1]<-0
  
  if(any(n.mono>=3)) {
    index.2 <- max(which(n.mono>=3))
    
    if(index.2<length(doses)) {
      index.3<-(min(index.2+1, length(doses)):length(doses))
      Pi.MTD.combo[index.3] <-0
    }
  } else{
    Pi.MTD.combo[1:length(doses)] <-0
  }
  
  admissible.doses.combo<-which(Pi.MTD.combo>0, arr=T)
  next.dose.combo<-which.max(Pi.MTD.combo)
  
  if(all(Pi.MTD.combo==0)){
    admissible.doses.combo<-next.dose.combo<-0
  }
  
}
  
  if(prediction){
    d.predict<-seq(1, 30, 0.5)
    combo.predict<-rep(0, length(d.predict))
    Pi.MTD.predict<-Pi.above.predict<-toxicity.predict<-c()
    
    for (j in 1:length(d.predict)){
      LP.predict <- a01 + a11 * log(d.predict[j]/D.ref) + a21 * combo.predict[j]
      LP <- pmin(pmax(LP, -10), 10)
      odds <- exp(LP)
      Pi <- odds / (1 + odds)
      Pi.MTD.predict[j]<- mean(Pi < 0.30) - mean(Pi < 0.20)
      Pi.above.predict[j] <-  mean(Pi > 0.30)
      toxicity.predict[j] <-mean(Pi)
    }
    
    Pi.MTD.predict[which(Pi.above.predict>c.overdose)] <-0
    
    if(all((no.DLT/N)>=1/3 & coherence.up)) {
      index<-which(d.predict>doses[current.dose])
      Pi.MTD.predict[index]<-0
    } else{
      index <-which(d.predict>doses[current.dose+1])
      Pi.MTD.predict[index]<-0
    }
    
    admissible.doses.predict <-d.predict[which(Pi.MTD.predict>0,arr=T)]
    
  }
  

  if(!prediction){
    output <- list(
      NextDose.Mono = next.dose.mono,
      Target.Prob.Mono = Pi.MTD.mono.store,
      Target.Prob.Const.Mono = Pi.MTD.mono,
      Overdose.Mono = Pi.above.mono,
      Toxicity.Est.Mono = toxicity.mono,
      no.DLT = no.DLT,
      Admissible.Mono = admissible.doses.mono,
      DLTs.Mono = s.mono,
      Data.Mono = n.mono,
      Lower.Mono = LCI.mono,
      Upper.Mono = UCI.mono,
      NextDose.Combo = next.dose.combo,
      Target.Prob.Combo = Pi.MTD.combo.store,
      Target.Prob.Const.Combo = Pi.MTD.combo,
      Overdose.Combo = Pi.above.combo,
      Toxicity.Est.Combo = toxicity.combo,
      Admissible.Combo = admissible.doses.combo,
      DLTs.Combo = s.combo,
      Data.Combo = n.combo,
      Lower.Combo = LCI.combo,
      Upper.Combo = UCI.combo)
    } else {
        output <- list(
          NextDose.Mono = next.dose.mono,
          Target.Prob.Mono = Pi.MTD.mono.store,
          Target.Prob.Const.Mono = Pi.MTD.mono,
          Overdose.Mono = Pi.above.mono,
          Toxicity.Est.Mono = toxicity.mono,
          no.DLT = no.DLT,
          Admissible.Mono = admissible.doses.mono,
          DLTs.Mono = s.mono,
          Data.Mono = n.mono,
          Lower.Mono = LCI.mono,
          Upper.Mono = UCI.mono,
          NextDose.Combo = next.dose.combo,
          Target.Prob.Combo = Pi.MTD.combo.store,
          Target.Prob.Const.Combo = Pi.MTD.combo,
          Overdose.Combo = Pi.above.combo,
          Toxicity.Est.Combo = toxicity.combo,
          Admissible.Combo = admissible.doses.combo,
          DLTs.Combo = s.combo,
          Data.Combo = n.combo,
          Lower.Combo = LCI.combo,
          Upper.Combo = UCI.combo,
          Target.Prob.Predict = Pi.MTD.predict, 
          Overdose.Predict = Pi.above.predict, 
          Tox.Est.Predict = toxicity.predict, 
          Admissible.Doses.Predict = admissible.doses.predict 
        )
      }

example <- output

# Dose levels
doses <- c(20,40,80,160,320,640,960)

# Construct Monotherapy Table
output.table.mono <- matrix(ncol=length(doses), nrow=7)
rownames(output.table.mono) <- c("Dose", "Patients", "DLTs", "Mean Toxicity", "95% CI", "Overdose Probability", "Target Probability")
output.table.mono[1,] <- paste(doses, "mg", sep="")
output.table.mono[2,] <- paste("n=", example$Data.Mono, sep="")
output.table.mono[3,] <- paste("DLTs=", example$DLTs.Mono, sep="")
output.table.mono[4,] <- paste("Mean Tox=", round(example$Toxicity.Est.Mono, 2), sep="")
output.table.mono[5,] <- paste("95\\%CI=(", round(example$Lower.Mono, 2), ",", round(example$Upper.Mono, 2), ")", sep="")
output.table.mono[6,] <- paste("Overdose=", round(100 * example$Overdose.Mono), "\\%", sep="")
output.table.mono[7,] <- paste("Target=", round(100 * example$Target.Prob.Mono), "\\%", sep="")

# Construct Combination Therapy Table
output.table.combo <- matrix(ncol=length(doses), nrow=7)
rownames(output.table.combo) <- c("Dose", "Patients", "DLTs", "Mean Toxicity", "95% CI", "Overdose Probability", "Target Probability")
output.table.combo[1,] <- paste(doses, "mg", sep="")
output.table.combo[2,] <- paste("n=", example$Data.Combo, sep="")
output.table.combo[3,] <- paste("DLTs=", example$DLTs.Combo, sep="")
output.table.combo[4,] <- paste("Mean Tox=", round(example$Toxicity.Est.Combo, 2), sep="")
output.table.combo[5,] <- paste("95\\%CI=(", round(example$Lower.Combo, 2), ",", round(example$Upper.Combo, 2), ")", sep="")
output.table.combo[6,] <- paste("Overdose=", round(100 * example$Overdose.Combo), "\\%", sep="")
output.table.combo[7,] <- paste("Target=", round(100 * example$Target.Prob.Combo), "\\%", sep="")

# View the tables
print("Monotherapy Table")
print(output.table.mono)
print("Combination Therapy Table")
print(output.table.combo)

# Write to CSV files
write.csv(output.table.mono, "Monotherapy-SRC-Meeting-07.03-Results.csv", row.names = TRUE, na="")
write.csv(output.table.combo, "Combination-SRC-Meeting-07.03.Results.csv", row.names = TRUE, na="")


########

####
# Print Results Table in Latex Format (with colour coding)
####
output.table.mono.colour<-output.table.mono

for(ii in 1:length(doses)){
  ttext<-output.table.mono[1,ii]
  if(example$Overdose.Mono[ii]>c.overdose){
    colour.name<-"coralred"
  }else{
    
    if(example$Target.Prob.Const.Mono[ii]==0){
      colour.name<-"azure"
    }else{
      colour.name<-"brightgreen"
    }
    
  }
  
  ttext.col<-paste0("\\cellcolor{", colour.name, "}", ttext)
  output.table.mono.colour[1,ii]<-ttext.col
}


####

print(xtable(output.table.mono.colour), sanitize.text.function = identity,include.rownames=FALSE,include.colnames=FALSE, size="\\tiny")


latex<-print(xtable(output.table.mono.colour,), sanitize.text.function = identity,include.rownames=FALSE,include.colnames=FALSE, size="\\normalsize")
writeLines(
  c(
    "\\documentclass[12pt]{article}",
    "\\usepackage[landscape,left=10mm,right=20mm,top=60mm,bottom=20mm]{geometry}",
    "\\usepackage[table]{xcolor}",
    "\\usepackage{color}",
    "\\definecolor{azure}{rgb}{0.0, 0.5, 1.0}",
    "\\definecolor{brightgreen}{rgb}{0.4, 1.0, 0.0}",
    "\\definecolor{coralred}{rgb}{1.0, 0.25, 0.25}",
    "\\begin{document}",
    "\\thispagestyle{empty}",
    latex,
    "\\end{document}"
  ),
  "table.tex"
)


####
output.table.combo.colour<-output.table.combo

for(ii in 1:length(doses)){
  ttext<-output.table.combo[1,ii]
  if(example$Overdose.Combo[ii]>c.overdose){
    colour.name<-"coralred"
  }else{
    
    if(example$Target.Prob.Const.Combo[ii]==0){
      colour.name<-"azure"
    }else{
      colour.name<-"brightgreen"
    }
    
  }
  
  ttext.col<-paste0("\\cellcolor{", colour.name, "}", ttext, "+Combo")
  output.table.combo.colour[1,ii]<-ttext.col
}

print(xtable(output.table.combo.colour), sanitize.text.function = identity,include.rownames=FALSE,include.colnames=FALSE, size="\\tiny")

latex<-print(xtable(output.table.combo.colour,), sanitize.text.function = identity,include.rownames=FALSE,include.colnames=FALSE, size="\\normalsize")
writeLines(
  c(
    "\\documentclass[12pt]{article}",
    "\\usepackage[landscape,left=10mm,right=20mm,top=60mm,bottom=20mm]{geometry}",
    "\\usepackage[table]{xcolor}",
    "\\usepackage{color}",
    "\\definecolor{azure}{rgb}{0.0, 0.5, 1.0}",
    "\\definecolor{brightgreen}{rgb}{0.4, 1.0, 0.0}",
    "\\definecolor{coralred}{rgb}{1.0, 0.25, 0.25}",
    "\\begin{document}",
    "\\thispagestyle{empty}",
    latex,
    "\\end{document}"
  ),
  "table2.tex"
)

