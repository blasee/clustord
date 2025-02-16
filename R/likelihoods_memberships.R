assignments <- function(pp.m) {
    nelements <- nrow(pp.m)
    nclus <- ncol(pp.m)

    assignments <- vector("list",nclus)
    for (idx in 1:nclus) assignments[[idx]] = (1:nelements)[pp.m[,idx]==apply(pp.m,1,max)]
    assignments
}

Bicluster.IncllC <- function(invect, model, ydf, rowc_mm, colc_mm, cov_mm, pi_v, kappa_v,
                             param_lengths, RG, CG, p, n, q,
                             constraint_sum_zero=TRUE)
{
    parlist <- unpack_parvec(invect, model, param_lengths, n, p, q, RG, CG,
                             constraint_sum_zero)

    pi_v[pi_v==0]=lower.limit
    kappa_v[kappa_v==0]=lower.limit

    # Full evaluation using the columns.
    # Use if CG^p is small enough.
    # Construct n*p*RG*CG*q array of Multinomial terms:
    multi.arr = array(NA,c(n,p,RG,CG))
    for(ii in 1:n){
        for(jj in 1:p){
            for(rr in 1:RG){
                for(cc in 1:CG){
                    ij <- which(ydf$ROW==ii & ydf$COL==jj)
                    if(length(ij) == 1) {
                        yval <- as.numeric(ydf$Y[ij])

                        linear_part = 0;
                        if (param_lengths["rowc"] > 0) {
                            linear_part <- linear_part + parlist$rowc[rr];
                        }
                        if (param_lengths["colc"] > 0) {
                            linear_part <- linear_part + parlist$colc[cc];
                        }
                        if (param_lengths["rowc_colc"] > 0) {
                            linear_part <- linear_part + parlist$rowc_colc[rr,cc];
                        }

                        if (param_lengths["row"] > 0) {
                            linear_part <- linear_part + parlist$row[ii];
                        }
                        if (param_lengths["col"] > 0) {
                            linear_part <- linear_part + parlist$col[jj];
                        }
                        if (param_lengths["rowc_col"] > 0) {
                            linear_part <- linear_part + parlist$rowc_col[rr,jj];
                        }
                        if (param_lengths["colc_row"] > 0) {
                            linear_part <- linear_part + parlist$colc_row[cc,ii];
                        }

                        if (param_lengths["rowc_cov"] > 0) {
                            linear_part <- linear_part + sum(rowc_mm[ij,]*parlist$rowc_cov[rr,])
                        }
                        if (param_lengths["colc_cov"] > 0) {
                            linear_part <- linear_part + sum(colc_mm[ij,]*parlist$colc_cov[cc,])
                        }
                        if (param_lengths["cov"] > 0) {
                            linear_part <- linear_part + sum(cov_mm[ij,]*parlist$cov)
                        }

                        theta_sum = 0;
                        if (model == "OSM") {
                            theta_all <- c(1,exp(mu[2:q] + phi[2:q]*linear_part))
                            theta = theta_all[yval]/theta_sum;
                        } else if (model == "POM") {
                            theta_all[1] <- expit(mu[0] - linear_part)
                            theta_sum = theta_all[1]
                            for (kk in 2:q-1) {
                                theta_all[kk] = rcpp_expit(mu[kk] - linear_part) -
                                    rcpp_expit(mu[kk-1] - linear_part);
                                theta_sum <- theta_sum + theta_all[kk];
                            }
                            theta_all[q] = 1-theta_sum;
                            theta = theta_all[yval];
                        } else if (model == "Binary") {
                            theta_all <- c(1, exp(mu[1] + linear_part))
                            theta = theta_all[yval]/sum(theta_all)
                        }

                        if (theta <= 0) {
                            theta = 0.0000000001;
                        }

                        multi.arr[ii,jj,rr,cc] <- theta
                    }
                }
            }
        }
    }

    combos.mat <- as.matrix(expand.grid(rep(list(1:CG),p)))
    # combos.mat has one row per combination of c selections.
    AA <- nrow(combos.mat)
    Aair.a  <- array(NA,c(AA,n,RG))
    Bair.a  <- array(NA,c(AA,n,RG))
    Bai.m   <- matrix(NA,AA,n)
    Dai.m   <- matrix(NA,AA,n)
    Ea.v    <- rep(NA,AA)
    alpha.v <- rep(NA,AA)
    m.a    <- array(NA,c(n,p,RG))  # Multi. array for current combo
    for (aa in 1:AA)
    {
        # Vector of c selections:
        c.v <- combos.mat[aa,]
        # Find the kappa product:
        alpha.v[aa] <- prod(kappa_v[c.v])
        if (alpha.v[aa]>0)
        {
            # Pick out elements of multi.arr where each col has known CG:
            for (ii in 1:n) for (jj in 1:p) for (rr in 1:RG)
                m.a[ii,jj,rr] <- multi.arr[ii,jj,rr,c.v[jj]]
            # Calculate and store row aa of Aair.a:
            for (ii in 1:n) for (rr in 1:RG)
                Aair.a[aa,ii,rr] <-  log(pi_v[rr]) + sum(log(m.a[ii,,rr]),na.rm=TRUE)

            # May have NA if pi_v[rr]=0, don't use those terms.
            max.Aair <- apply(Aair.a[aa,,],1,max,na.rm=T)

            for (ii in 1:n)
            {
                Bai.m[aa,ii]   <- max.Aair[ii]
                Dai.m[aa,ii]   <- sum(exp(Aair.a[aa,ii,]-max.Aair[ii]))
            }

            Ea.v[aa] <- sum(Bai.m[aa,]) + sum(log(Dai.m[aa,]),na.rm=T)
            Ea.v[aa] <- Ea.v[aa] + log(alpha.v[aa])
        }
    }
    M.val <- max(Ea.v, na.rm=TRUE)
    logl <- M.val + log(sum(exp(Ea.v-M.val),na.rm=TRUE))
    logl
}

# Rows expansion (use if RG^n small enough):
Bicluster.IncllR <- function(long.df, theta, pi_v, kappa_v)
{
    n <- max(long.df$ROW)
    p <- max(long.df$COL)
    q <- length(levels(long.df$Y))
    RG <- length(pi_v)
    CG <- length(kappa_v)

    theta[theta<=0]=lower.limit
    pi_v[pi_v==0]=lower.limit
    kappa_v[kappa_v==0]=lower.limit

    # Full evaluation using the rows.
    # Use if RG^n is small enough.
    # Construct n*p*RG*CG*q array of Multinomial terms:
    multi.arr = array(NA,c(n,p,RG,CG))
    for(i in 1:n){
        for(j in 1:p){
            for(r in 1:RG){
                for(c in 1:CG){
                    for(k in 1:q){
                        yval <- as.numeric(long.df$Y[long.df$ROW==i & long.df$COL==j])
                        if(length(yval)==1 && yval==k) multi.arr[i,j,r,c]=theta[r,c,k]
                    }
                }
            }
        }
    }
    combos.mat <- as.matrix(expand.grid(rep(list(1:RG),n)))
    # combos.mat has one row per combination of r selections.
    AA <- nrow(combos.mat)
    Aajc.a  <- array(NA,c(AA,p,CG))
    Bajc.a  <- array(NA,c(AA,p,CG))
    Baj.m   <- matrix(NA,AA,p)
    Daj.m   <- matrix(NA,AA,p)
    Ea.v    <- rep(NA,AA)
    alpha.v <- rep(NA,AA)
    m.a    <- array(NA,c(n,p,CG))  # Multi. array for current combo
    for (aa in 1:AA)
    {
        # Vector of r selections:
        r.v <- combos.mat[aa,]
        # Find the pi product:
        alpha.v[aa] <- prod(pi_v[r.v])
        if (alpha.v[aa]>0)
        {
            # Pick out elements of multi.arr where each row has known RG:
            for (ii in 1:n) for (jj in 1:p) for (cc in 1:CG)
                m.a[ii,jj,cc] <- multi.arr[ii,jj,r.v[ii],cc]
            # Calculate and store row aa of Aair.a:
            for (jj in 1:p) for (cc in 1:CG)
                Aajc.a[aa,jj,cc] <-  log(kappa_v[cc]) + sum(log(m.a[,jj,cc]),na.rm=TRUE)
            # May have NA if kappa_v[cc]=0, don't use those terms.
            max.Aajc <- apply(Aajc.a[aa,,],1,max,na.rm=T)

            for (jj in 1:p)
            {
                Baj.m[aa,jj]   <- max.Aajc[jj]
                Daj.m[aa,jj]   <- sum(exp(Aajc.a[aa,jj,]-max.Aajc[jj]))
            }

            Ea.v[aa] <- sum(Baj.m[aa,]) + sum(log(Daj.m[aa,]),na.rm=T)
            Ea.v[aa] <- Ea.v[aa] + log(alpha.v[aa])
        }
    }
    M.val <- max(Ea.v, na.rm=TRUE)
    logl <- M.val + log(sum(exp(Ea.v-M.val),na.rm=TRUE))
    logl
}
