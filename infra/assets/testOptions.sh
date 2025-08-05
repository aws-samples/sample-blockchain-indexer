#!/bin/bash

# Function to display usage
show_usage() {
    echo "Usage: $0 -d <dataset> -c <chain>"
    echo "Dataset options: blocks, transactions, logs"
    echo "Chain options: ethereum, sepolia"
    exit 1
}

# Initialize variables
dataset=""
chain=""

# Parse command line options
while getopts "d:c:" opt; do
    case $opt in
        d) dataset="$OPTARG" ;;
        c) chain="$OPTARG" ;;
        ?) show_usage ;;
    esac
done

# Check if both options are provided
if [ -z "$dataset" ] || [ -z "$chain" ]; then
    echo "Error: Both dataset (-d) and chain (-c) options are required"
    show_usage
fi

# Validate dataset
case $dataset in
    blocks|transactions|logs) ;;
    *)
        echo "Error: Invalid dataset '$dataset'"
        echo "Valid datasets are: blocks, transactions, logs"
        exit 1
        ;;
esac

# Validate chain
case $chain in
    ethereum|sepolia) ;;
    *)
        echo "Error: Invalid chain '$chain'"
        echo "Valid chains are: ethereum, sepolia"
        exit 1
        ;;
esac

# If we get here, all validations passed
echo "Valid options provided:"
echo "Dataset: $dataset"
echo "Chain: $chain"
