read_count <-
function (filetype, path, out_dir) 
{
    if (filetype == "csv") {
        raw_count = read.csv(path, header = TRUE, row.names = 1)
    }
    else if (filetype == "txt") {
        raw_count = read.table(path, header = TRUE, row.names = 1)
    }
    else {
        print("filetype can be either 'csv' or 'txt'!")
        stop()
    }
    raw_count = as.matrix(raw_count)
    print(paste("number of genes in raw count matrix", nrow(raw_count)))
    print(paste("number of cells in raw count matrix", ncol(raw_count)))

    totalCounts_by_cell = colSums(raw_count)
    saveRDS(totalCounts_by_cell, file = paste0(out_dir, "totalCounts_by_cell.rds"))
    totalCounts_by_cell[totalCounts_by_cell == 0] = 1
    raw_count = sweep(raw_count, MARGIN = 2, totalCounts_by_cell/10^6, 
        FUN = "/")
    if (min(raw_count) < 0) {
        stop("smallest read count cannot be negative!")
    }
    count_lnorm = log10(raw_count + 1.01)
    return(count_lnorm)
}
