
find_hv_genes = function(count, I, J){
  count_nzero = lapply(1:I, function(i) setdiff(count[i, ], log10(1.01)))
  mu = sapply(count_nzero, mean)
  mu[is.na(mu)] = 0
  sd = sapply(count_nzero, sd)
  sd[is.na(sd)] = 0
  cv = sd/mu
  cv[is.na(cv)] = 0
  # sum(mu >= 1 & cv >= quantile(cv, 0.25), na.rm = TRUE)
  high_var_genes = which(mu >= 1 & cv >= quantile(cv, 0.25))
  if(length(high_var_genes) < 500){ 
    high_var_genes = 1:I}
  count_hv = count[high_var_genes, ]
  return(count_hv)
}

find_neighbors = function(count_hv, labeled, J, Kcluster = NULL, 
                          ncores, cell_labels = NULL){
  ## dimeansion reduction
  pca = prcomp(t(count_hv))
  eigs = (pca$sdev)^2
  var_cum = cumsum(eigs)/sum(eigs)
  npc = which.max(var_cum > 0.4)
  if (labeled == FALSE){ npc = max(npc, Kcluster) }
  if (npc < 3){ npc = 3 }
  mat_pcs = t(pca$x[, 1:npc]) # columns are cells
  
  ## detect outliers
  dist_cells_list = mclapply(1:J, function(id1){
    sapply(1:J, function(id2){
      if(id1 <= id2) return(0)
      sse = sum((mat_pcs[, id1] - mat_pcs[, id2])^2)
      sqrt(sse)
    })
  }, mc.cores = ncores)
  dist_cells = matrix(0, nrow = J, ncol = J)
  for(cellid in 1:J){dist_cells[cellid, ] = dist_cells_list[[cellid]]}
  dist_cells = dist_cells + t(dist_cells)
  
  if (labeled == FALSE){
    min_dist = sapply(1:J, function(i){
      min(dist_cells[i, -i])
    })
    iqr = quantile(min_dist, 0.75) - quantile(min_dist, 0.25)
    outliers = which(min_dist > 1.5 * iqr + quantile(min_dist, 0.75))
    
    ## clustering
    non_out = setdiff(1:J, outliers)
    spec_res = specc(t(mat_pcs[, non_out]), centers = Kcluster, kernel = "rbfdot")
    print("cluster sizes:")
    print(spec_res@size)
    nbs = rep(NA, J)
    nbs[non_out] = spec_res
    return(list(dist_cells = dist_cells, clust = nbs))
  }
  
  if(labeled == TRUE){
    if(class(cell_labels) == "character"){
      labels_uniq = unique(cell_labels)
      labels_mth = 1:length(labels_uniq)
      names(labels_mth) = labels_uniq
      clust = labels_mth[cell_labels]
    }else{
      clust = cell_labels
    }
    return(list(dist_cells = dist_cells, clust = clust))
  }
}

find_va_genes = function(parslist, subcount){
  point = log10(1.01)
  valid_genes = which( (rowSums(subcount) > point * ncol(subcount)) &
                         complete.cases(parslist) )
  if(length(valid_genes) == 0) return(valid_genes)
  # find out genes that violate assumption
  mu = parslist[, "mu"]
  sgene1 = which(mu <= log10(1+1.01))
  # sgene2 = which(mu <= log10(10+1.01) & mu - parslist[,5] > log10(1.01))
  
  dcheck1 = dgamma(mu+1, shape = parslist[, "alpha"], rate = parslist[, "beta"])
  dcheck2 = dnorm(mu+1, mean = parslist[, "mu"], sd = parslist[, "sigma"])
  sgene3 = which(dcheck1 >= dcheck2 & mu <= 1)
  sgene = union(sgene1, sgene3)
  valid_genes = setdiff(valid_genes, sgene)
  return(valid_genes)
}

impute_nnls = function(Ic, cellid, subcount, droprate, geneid_drop, 
                  geneid_obs, nbs, distc){
  yobs = subcount[ ,cellid]
  if (length(geneid_drop) == 0 | length(geneid_drop) == Ic) {
    return(yobs) }  
  yimpute = rep(0, Ic)
  
  xx = subcount[geneid_obs, nbs]
  yy = subcount[geneid_obs, cellid]
  ximpute = subcount[geneid_drop, nbs]
  num_thre = 1000
  if(ncol(xx) >= min(num_thre, nrow(xx))){
    if (num_thre >= nrow(xx)){
      new_thre = round((2*nrow(xx)/3))
    }else{ new_thre = num_thre}
    filterid = order(distc[cellid, -cellid])[1: new_thre]
    xx = xx[, filterid, drop = FALSE]
    ximpute = ximpute[, filterid, drop = FALSE]
  }
  set.seed(cellid)
  nnls = penalized(yy, penalized = xx, unpenalized = ~0,
                  positive = TRUE, lambda1 = 0, lambda2 = 0, 
                  maxiter = 3000, trace = FALSE)
  ynew = penalized::predict(nnls, penalized = ximpute, unpenalized = ~0)[,1]
  
  yimpute[geneid_drop] = ynew
  yimpute[geneid_obs] = yobs[geneid_obs]
  return(yimpute)
}


imputation_model8 = function(count, labeled, point, drop_thre = 0.5, Kcluster = 10, 
                             out_dir, ncores){
  count = as.matrix(count)
  I = nrow(count)
  J = ncol(count)
  count_imp = count
  
  # find highly variable genes
  count_hv = find_hv_genes(count, I, J)
  
  print("inferring cell similarities ...")
  set.seed(Kcluster)
  neighbors_res = find_neighbors(count_hv = count_hv, labeled = FALSE, J = J, 
                                 Kcluster = Kcluster, ncores = ncores)
  dist_cells = neighbors_res$dist_cells
  clust = neighbors_res$clust
  saveRDS(clust, file = paste0(out_dir, "clust.rds"))
  # mixture model
  nclust = sum(!is.na(unique(clust)))
  cl = makeCluster(ncores)
  registerDoParallel(cl)
  
  for(cc in 1:nclust){
    print(paste("estimating dropout probability for type", cc, "..."))
    paste0(out_dir, "pars", cc, ".rds")
    get_mix_parameters(count = count[, which(clust == cc), drop = FALSE], 
                       point = log10(1.01),
                       path = paste0(out_dir, "pars", cc, ".rds"), ncores = ncores)
    
    print(paste("imputing dropout values for type", cc, "..."))
    
    cells = which(clust == cc)
    if(length(cells) <= 1) { next }
    parslist = readRDS(paste0(out_dir, "pars", cc, ".rds"))
    valid_genes = find_va_genes(parslist, subcount = count[, cells])
    if(length(valid_genes) <= 10){ next }

    subcount = count[valid_genes, cells, drop = FALSE]
    Ic = length(valid_genes)
    Jc = ncol(subcount)
    parslist = parslist[valid_genes, ]
    
    droprate = t(sapply(1:Ic, function(i) {
      wt = calculate_weight(subcount[i, ], parslist[i, ])
      return(wt[, 1])
    }))
    mucheck = sweep(subcount, MARGIN = 1, parslist[, "mu"], FUN = ">")
    droprate[mucheck & droprate > drop_thre] = 0
    # dropouts
    setA = lapply(1:Jc, function(cellid){
      which(droprate[, cellid] > drop_thre)
    })
    # non-dropouts
    setB = lapply(1:Jc, function(cellid){
      which(droprate[, cellid] <= drop_thre)
    })
    # imputation
    # registerDoSNOW(cl)
    subres = foreach(cellid = 1:Jc, .packages = c("penalized"), 
                     .combine = cbind, .export = c("impute_nnls")) %dopar% {
      if (cellid %% 100 == 0) {gc()}
      nbs = setdiff(1:Jc, cellid)
      if (length(nbs) == 0) {return(NULL)}
      geneid_drop = setA[[cellid]]
      geneid_obs = setB[[cellid]]
      y = try(impute_nnls(Ic, cellid, subcount, droprate, geneid_drop, 
                          geneid_obs, nbs, distc = dist_cells[cells, cells]), 
              silent = TRUE)
      if (class(y) == "try-error") {
        # print(y)
        y = subcount[, cellid, drop = FALSE]
      }
      return(y)
    }
    
    
    count_imp[valid_genes, cells] = subres
  }
  stopCluster(cl)
  outlier = which(is.na(clust))
  count_imp[count_imp < point] = point
  return(list(count_imp = count_imp, outlier = outlier))
}

imputation_wlabel_model8 = function(count, labeled, cell_labels = NULL, point, drop_thre, 
                                    Kcluster = NULL, out_dir, ncores){
  if(!(class(cell_labels) %in% c("character", "numeric", "integer"))){
    stop("cell_labels should be a character or integer vector!")
  }
  
  count = as.matrix(count)
  I = nrow(count)
  J = ncol(count)
  count_imp = count
  
  count_hv = find_hv_genes(count, I, J)
  neighbors_res = find_neighbors(count_hv = count_hv, labeled = TRUE, J = J,  
                                 ncores = ncores, cell_labels = cell_labels)
  dist_cells = neighbors_res$dist_cells
  clust = neighbors_res$clust
  
  # mixture model
  nclust = sum(!is.na(unique(clust)))
  cl = makeCluster(ncores)
  registerDoParallel(cl)
  
  for(cc in 1:nclust){
    print(paste("estimating dropout probability for type", cc, "..."))
    paste0(out_dir, "pars", cc, ".rds")
    get_mix_parameters(count = count[, which(clust == cc), drop = FALSE], 
                       point = log10(1.01),
                       path = paste0(out_dir, "pars", cc, ".rds"), ncores = ncores)
    
    print(paste("imputing dropout values for type", cc, "..."))
    
    cells = which(clust == cc)
    if(length(cells) <= 1){ next }
    parslist = readRDS(paste0(out_dir, "pars", cc, ".rds"))
    valid_genes = find_va_genes(parslist, subcount = count[, cells])
    if(length(valid_genes) <= 1){ next }
    
    subcount = count[valid_genes, cells, drop = FALSE]
    Ic = length(valid_genes)
    Jc = ncol(subcount)
    parslist = parslist[valid_genes, , drop = FALSE]
    
    droprate = t(sapply(1:Ic, function(i) {
      wt = calculate_weight(subcount[i, ], parslist[i, ])
      return(wt[, 1])
    }))
    mucheck = sweep(subcount, MARGIN = 1, parslist[, "mu"], FUN = ">")
    droprate[mucheck & droprate > drop_thre] = 0
    # dropouts
    setA = lapply(1:Jc, function(cellid){
      which(droprate[, cellid] > drop_thre)
    })
    # non-dropouts
    setB = lapply(1:Jc, function(cellid){
      which(droprate[, cellid] <= drop_thre)
    })
    # imputation
    # registerDoSNOW(cl)
    subres = foreach(cellid = 1:Jc, .packages = c("penalized"), 
                     .combine = cbind, .export = c("impute_nnls")) %dopar% {
      if (cellid %% 100 == 0) {gc()}
      # print(cellid)
      nbs = setdiff(1:Jc, cellid)
      if (length(nbs) == 0) {return(NULL)}
      geneid_drop = setA[[cellid]]
      geneid_obs = setB[[cellid]]
      y = try(impute_nnls(Ic, cellid, subcount, droprate, geneid_drop, 
                          geneid_obs, nbs, distc = dist_cells[cells, cells]),
              silent = TRUE)
      if (class(y) == "try-error") {
        # print(y)
        y = subcount[, cellid, drop = FALSE]
      }
      return(y)
    }
    count_imp[valid_genes, cells] = subres
  }
  stopCluster(cl)
  outlier = integer(0)
  count_imp[count_imp < point] = point
  return(list(count_imp = count_imp, outlier = outlier))

  }