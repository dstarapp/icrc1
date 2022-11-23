import Prim "mo:prim";

import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Hash "mo:base/Hash";
import Result "mo:base/Result";

import ExperimentalStableMemory "mo:base/ExperimentalStableMemory";

import Itertools "mo:Itertools/Iter";
import StableTrieMap "mo:StableTrieMap";
import U "../Utils";
import T "../Types";

shared ({ caller = ledger_canister_id }) actor class Archive() : async T.ArchiveInterface {

    type Transaction = T.Transaction;
    type MemoryBlock = {
        offset : Nat64;
        size : Nat;
    };

    stable let GB = 1024 ** 3;
    stable let MAX_MEMORY = 32 * GB;
    stable let BUCKET_SIZE = 1000;
    stable let MAX_TRANSACTIONS_PER_REQUEST = 5000;

    stable let MIN_PAGES : Nat64 = 32; // 2MiB == 32 * 64KiB
    stable let PAGES_TO_GROW : Nat64 = 4096; // 128MiB

    stable var filled_pages : Nat64 = 0;
    stable var memory_pages : Nat64 = ExperimentalStableMemory.size();

    stable var offset : Nat64 = 0;
    stable var filled_buckets = 0;
    stable var trailing_txs = 0;

    stable let txStore = StableTrieMap.new<Nat, [MemoryBlock]>();

    public shared ({ caller }) func append_transactions(txs : [Transaction]) : async Result.Result<(), Text> {

        if (caller != ledger_canister_id) {
            return #err("Unauthorized Access: Only the owner can access this canister");
        };

        if (Prim.rts_memory_size() >= MAX_MEMORY) {
            return #err("Memory Limit: The archive canister cannot store any more transactions");
        };

        var txs_iter = txs.vals();

        if (trailing_txs > 0) {
            let last_bucket = StableTrieMap.get(
                txStore,
                Nat.equal,
                U.hash,
                filled_buckets,
            );

            switch (last_bucket) {
                case (?last_bucket) {
                    let new_bucket = Iter.toArray(
                        Itertools.take(
                            Itertools.chain(
                                last_bucket.vals(),
                                Iter.map(txs.vals(), store_tx),
                            ),
                            BUCKET_SIZE,
                        ),
                    );

                    if (new_bucket.size() == BUCKET_SIZE) {
                        let offset = (BUCKET_SIZE - last_bucket.size()) : Nat;

                        txs_iter := Itertools.fromArraySlice(txs, offset, txs.size());
                    } else {
                        txs_iter := Itertools.empty();
                    };

                    store_bucket(new_bucket);

                };
                case (_) {};
            };
        };

        for (chunk in Itertools.chunks(txs_iter, BUCKET_SIZE)) {
            store_bucket(Array.map(chunk, store_tx));
        };

        #ok();
    };

    func total_txs() : Nat {
        (filled_buckets * BUCKET_SIZE) + trailing_txs;
    };

    public shared query func total_transactions() : async Nat {
        total_txs();
    };

    public shared query func get_transaction(tx_index : T.TxIndex) : async ?Transaction {
        let bucket_key = tx_index / BUCKET_SIZE;

        let opt_bucket = StableTrieMap.get(
            txStore,
            Nat.equal,
            U.hash,
            bucket_key,
        );

        switch (opt_bucket) {
            case (?bucket) {
                let i = tx_index % BUCKET_SIZE;
                if (i < bucket.size()) {
                    ?get_tx(bucket[tx_index % BUCKET_SIZE]);
                } else {
                    null;
                };
            };
            case (_) {
                null;
            };
        };
    };

    public shared query func get_transactions(req : T.GetTransactionsRequest) : async [Transaction] {
        let { start; length } = req;
        var iter = Itertools.empty<MemoryBlock>();

        let end = start + length;
        let start_bucket = start / BUCKET_SIZE;
        let end_bucket = (Nat.min(end, total_txs()) / BUCKET_SIZE) + 1;

        label _loop for (i in Itertools.range(start_bucket, end_bucket)) {
            let opt_bucket = StableTrieMap.get(
                txStore,
                Nat.equal,
                U.hash,
                i,
            );

            switch (opt_bucket) {
                case (?bucket) {
                    if (i == start_bucket) {
                        iter := Itertools.fromArraySlice(bucket, start % BUCKET_SIZE, Nat.min(bucket.size(), end));
                    } else if (i + 1 == end_bucket) {
                        let bucket_iter = Itertools.fromArraySlice(bucket, 0, end % BUCKET_SIZE);
                        iter := Itertools.chain(iter, bucket_iter);
                    } else {
                        iter := Itertools.chain(iter, bucket.vals());
                    };
                };
                case (_) { break _loop };
            };
        };

        Iter.toArray(
            Iter.map(
                Itertools.take(iter, MAX_TRANSACTIONS_PER_REQUEST),
                get_tx,
            ),
        );
    };

    public shared query func remaining_capacity() : async Nat {
        MAX_MEMORY - Prim.rts_memory_size();
    };

    func to_blob(tx : Transaction) : Blob {
        to_candid (tx);
    };

    func from_blob(tx : Blob) : Transaction {
        switch (from_candid (tx) : ?Transaction) {
            case (?tx) tx;
            case (_) Debug.trap("Could not decode tx blob");
        };
    };

    func store_tx(tx : Transaction) : MemoryBlock {
        let blob = to_blob(tx);

        if (memory_pages - filled_pages < MIN_PAGES) {
            ignore ExperimentalStableMemory.grow(PAGES_TO_GROW);
            memory_pages += PAGES_TO_GROW;
        };

        ExperimentalStableMemory.storeBlob(
            offset,
            blob,
        );

        let mem_block = {
            offset;
            size = blob.size();
        };

        offset += Nat64.fromNat(blob.size());

        mem_block;
    };

    func get_tx({ offset; size } : MemoryBlock) : Transaction {
        let blob = ExperimentalStableMemory.loadBlob(offset, size);

        let tx = from_blob(blob);
    };

    func store_bucket(bucket : [MemoryBlock]) {

        StableTrieMap.put(
            txStore,
            Nat.equal,
            U.hash,
            filled_buckets,
            bucket,
        );

        if (bucket.size() == BUCKET_SIZE) {
            filled_buckets += 1;
            trailing_txs := 0;
        } else {
            trailing_txs := bucket.size();
        };
    };
};
