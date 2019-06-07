(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

(**
    +---------------------------------+
    | Let's talk about naming tables! |
    +---------------------------------+

    Every typechecker or compiler that's more complicated than a toy project needs some way to look
    up the location of a given symbol, especially one that operates at the same scale as Hack and
    double especially as Hack moves towards generating data lazily on demand instead of generating
    all of the data up front during strictly defined typechecking phases. In Hack, the data
    structures that map from symbols to filenames and from filenames to symbol names are referred to
    as the "naming table," with the "forward naming table" mapping from filenames to symbol names
    and the "reverse naming table" mapping from symbol names to file names. We store the forward
    naming table as a standard OCaml map since we only read and write it from the main process, and
    we store the reverse naming table in shared memory since we want to allow rapid reads and writes
    from worker processes.

    So, to recap:
      - Forward naming table: OCaml map, maps filename -> symbols in file
      - Reverse naming table: shared memory, maps symbol name to filename it's defined in

    Seems simple enough, right? Unfortunately, this is where the real world and all of its attendant
    complexity comes in. The naming table (forward + reverse) is big. And not only is it big, its
    size is on the order of O(repo). This conflicts with our goal of making Hack use a flat amount
    of memory regardless of the amount of code we're actually typechecking, so it needs to go. In
    this case, we've chosen to use our existing saved state infrastructure and dump the naming
    table to a SQLite file which we can use to serve queries without having to store anything in
    memory other than just the differences between what's in the saved state and what's on disk.

    Right now, only the reverse naming table supports falling back to SQLite, so let's go through
    each operation that the reverse naming table supports and cover how it handles falling back to
    SQLite.


    +---------------------------------+
    | Reverse naming table operations |
    +---------------------------------+

    The reverse naming table supports three operations: [put], [get], and [delete]. [Put] is pretty
    simple, conceptually, but there's some trickiness with [delete] that would benefit from being
    covered in more detail, and that trickiness bleeds into how [get] works as well. One important
    consideration is that *the SQLite database is read-only.* The general idea of these operations
    is that shared memory stores only entries that have changed.

    PUT:
    [Put] is simple. Since the SQLite database is read-only and we use shared memory for storing any
    changes, we just put the value in shared memory.

                        +------------------+    +------------+
                        |                  |    |            |
                        |   Naming Heap    |    |   SQLite   |
                        |                  |    |            |
    [put key value] -----> [put key value] |    |            |
                        |                  |    |            |
                        +------------------+    +------------+

    DELETE:
    We're going to cover [delete] next because it's the only reason that [get] has any complexity
    beyond "look for the value in shared memory and if it's not there look for it in SQLite." At
    first glance, [delete] doesn't seem too difficult. Just delete the entry from shared memory,
    right? Well, that's fine... unless that key also exists in SQLite. If the value is in SQLite,
    then all that deleting it from shared memory does is make us start returning the stored SQLite
    value! This is bad, because if we just deleted a key of course we want [get] operations for it
    to return [None]. But okay, we can work around that. Instead of storing direct values in shared
    memory, we'll store an enum of [[Added of 'a | Deleted]]. Easy peasy!

    ...except what do we do if we want to delete a value in the main process, then add it again in a
    worker process? That would require changing a key's value in shared memory, which is something
    that we don't support due to data integrity concerns with multiple writers and readers. We could
    remove and re-add, except removal can only be done by master because of the same integrity
    concerns. So master would somehow need to know which entries will be added and prematurely
    remove the [Deleted] sentinel from them. This is difficult enough as to be effectively
    impossible.

    So what we're left needing is some way to delete values which can be undone by child processes,
    which means that undeleting a value needs to consist only of [add] operations to shared memory,
    and have no dependency on [remove]. Enter: the blocked entries heap.

    For each of the reverse naming table heaps (types, functions, and constants) we also create a
    heap that only stores values of a single-case enum: [Blocked]. The crucial difference between
    [Blocked] and [[Added of 'a | Deleted]] is that *we only check for [Blocked] if the value is
    not in the shared memory naming heap.* This means that we can effectively undelete an entry by
    using an only an [add] operation.  Exactly what we need! Thus, [delete] becomes:

                        +-----------------+    +---------------------+    +------------+
                        |                 |    |                     |    |            |
                        |   Naming Heap   |    |   Blocked Entries   |    |   SQLite   |
                        |                 |    |                     |    |            |
    [delete key] --+-----> [delete key]   |    |                     |    |            |
                   |    |                 |    |                     |    |            |
                   +----------------------------> [add key Blocked]  |    |            |
                        |                 |    |                     |    |            |
                        +-----------------+    +---------------------+    +------------+

    GET:
    Wow, what a ride, huh? Now that we know how to add and remove entries, let's make this actually
    useful and talk about how to read them! The general idea is that we first check to see if the
    value is in the shared memory naming heap. If so, we can return that immediately. If it's not
    in the naming heap, then we check to see if it's blocked. If it is, we immediately return
    [None]. If it's not in the naming heap, and it's not in the blocked entries, then and only then
    do we read the value from SQLite:

                        +-----------------+    +---------------------+    +------------------+
                        |                 |    |                     |    |                  |
                        |   Naming Heap   |    |   Blocked Entries   |    |      SQLite      |
                        |                 |    |                     |    |                  |
    [get key] -----------> [get key] is:  |    |                     |    |                  |
    [Some value] <---------- [Some value] |    |                     |    |                  |
                        |    [None] -------+   |                     |    |                  |
                        |                 | \  |                     |    |                  |
                        |                 |  +--> [get key] is:      |    |                  |
    [None] <--------------------------------------- [Some Blocked]   |    |                  |
                        |                 |    |    [None] -----------+   |                  |
                        |                 |    |                     | \  |                  |
                        |                 |    |                     |  +--> [get key] is:   |
    [Some value] <------------------------------------------------------------ [Some value]  |
    [None] <------------------------------------------------------------------ [None]        |
                        |                 |    |                     |    |                  |
                        +-----------------+    +---------------------+    +------------------+

    And we're done! I hope this was easy to understand and as fun to read as it was to write :)

    MINUTIAE:
    Q: When do we delete entries from the Blocked Entries heaps?
    A: Never! Once an entry has been removed at least once we never want to retrieve the SQLite
       version for the rest of the program execution.

    Q: Won't we just end up with a heap full of [Blocked] entries now?
    A: Not really. We only have to do deletions once to remove entries for dirty files, and after
       that it's not a concern. Plus [Blocked] entries are incredibly small in shared memory
       (although they do still occupy a hash slot).
*)

type forward_naming_table_delta =
  | Modified of FileInfo.t
  | Deleted
  [@@deriving show]
let _ = show_forward_naming_table_delta
type t =
  | Unbacked of FileInfo.t Relative_path.Map.t
  | Backed of forward_naming_table_delta Relative_path.Map.t
  [@@deriving show]
type fast = FileInfo.names Relative_path.Map.t
type saved_state_info = FileInfo.saved Relative_path.Map.t

(* The canon name (and assorted *Canon heaps) store the canonical name for a
   symbol, keyed off of the lowercase version of its name. We use the canon
   heaps to check for symbols which are redefined using different
   capitalizations so we can throw proper Hack errors for them. *)
let to_canon_name_key = String.lowercase_ascii
let canonize_set = SSet.map to_canon_name_key

type type_of_type =
  | TClass
  | TTypedef
  [@@deriving enum]

module Sqlite : sig
  val create_database :
    string ->
    ((int64 -> Relative_path.t -> FileInfo.t -> int) -> unit) ->
    unit
  val set_db_path : string -> unit
  val is_connected : unit -> bool
  val fold :
    init:'a ->
    f:(Relative_path.t -> FileInfo.t -> 'a -> 'a) ->
    local_changes:(forward_naming_table_delta Relative_path.Map.t) ->
    'a
  val get_file_info : Relative_path.t -> FileInfo.t option
  val get_type_pos : string -> case_insensitive:bool -> (Relative_path.t * type_of_type) option
  val get_fun_pos : string -> case_insensitive:bool -> Relative_path.t option
  val get_const_pos : string -> Relative_path.t option
end = struct
  let check_rc rc =
    if rc <> Sqlite3.Rc.OK && rc <> Sqlite3.Rc.DONE
    then failwith (Printf.sprintf "SQLite operation failed: %s" (Sqlite3.Rc.to_string rc))

  let column_str stmt idx =
    match Sqlite3.column stmt idx with
    | Sqlite3.Data.TEXT s -> s
    | data ->
      let msg =
        Printf.sprintf "Expected a string at column %d, but was %s"
          idx
          (Sqlite3.Data.to_string_debug data)
      in
      failwith msg

    let column_blob stmt idx =
      match Sqlite3.column stmt idx with
      | Sqlite3.Data.BLOB s -> s
      | data ->
        let msg =
          Printf.sprintf "Expected a blob at column %d, but was %s"
            idx
            (Sqlite3.Data.to_string_debug data)
        in
        failwith msg

  let column_int stmt idx =
    match Sqlite3.column stmt idx with
    | Sqlite3.Data.INT i -> i
    | data ->
      let msg =
        Printf.sprintf "Expected an int at column %d, but was %s"
          idx
          (Sqlite3.Data.to_string_debug data)
      in
      failwith msg

  let make_relative_path ~prefix_int ~suffix =
    let prefix =
      Core_kernel.Option.value_exn (Relative_path.prefix_of_enum (Int64.to_int prefix_int))
    in
    let full_suffix = Filename.concat (Relative_path.path_of_prefix prefix) suffix in
    Relative_path.create prefix full_suffix

  let fold_sqlite stmt ~f ~init =
    let rec helper acc =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.DONE -> acc
      | Sqlite3.Rc.ROW ->
        helper (f stmt acc)
      | rc -> failwith (Printf.sprintf "SQLite operation failed: %s" (Sqlite3.Rc.to_string rc))
    in
    helper init


  (* These are just done as modules to keep the SQLite for related tables close together. *)
  module FileInfoTable = struct
    let table_name = "NAMING_FILE_INFO"

    let create_table_sqlite =
      Printf.sprintf "
      CREATE TABLE IF NOT EXISTS %s(
        PRIMARY_KEY INTEGER PRIMARY KEY NOT NULL,
        PATH_PREFIX_TYPE INTEGER NOT NULL,
        PATH_SUFFIX TEXT NOT NULL,
        FILE_INFO BLOB
      );
      " table_name

    let insert_sqlite =
      Printf.sprintf "
        INSERT INTO %s
        (PRIMARY_KEY, PATH_PREFIX_TYPE, PATH_SUFFIX, FILE_INFO)
        VALUES (?, ?, ?, ?);
      " table_name

    let get_sqlite =
      Printf.sprintf "
        SELECT
          FILE_INFO
        FROM %s
        WHERE PATH_PREFIX_TYPE = ? AND PATH_SUFFIX = ?;
      " table_name

    let iter_sqlite =
      Printf.sprintf "
        SELECT
          PATH_PREFIX_TYPE,
          PATH_SUFFIX,
          FILE_INFO
        FROM %s
        ORDER BY PATH_PREFIX_TYPE, PATH_SUFFIX;
      " table_name

    let insert db primary_key relative_path file_info =
      let prefix_type = Relative_path.prefix_to_enum (Relative_path.prefix relative_path) in
      let suffix = Relative_path.suffix relative_path in
      let file_info_blob = Marshal.to_string (FileInfo.to_saved file_info) [Marshal.No_sharing] in
      let insert_stmt = Sqlite3.prepare db insert_sqlite in
      Sqlite3.bind insert_stmt 1 (Sqlite3.Data.INT primary_key) |> check_rc;
      Sqlite3.bind insert_stmt 2 (Sqlite3.Data.INT (Int64.of_int prefix_type)) |> check_rc;
      Sqlite3.bind insert_stmt 3 (Sqlite3.Data.TEXT suffix) |> check_rc;
      Sqlite3.bind insert_stmt 4 (Sqlite3.Data.BLOB file_info_blob) |> check_rc;
      Sqlite3.step insert_stmt |> check_rc;
      Sqlite3.finalize insert_stmt |> check_rc

    let get_file_info db path =
      let get_stmt = Sqlite3.prepare db get_sqlite in
      let prefix_type = Relative_path.prefix_to_enum (Relative_path.prefix path) in
      let suffix = Relative_path.suffix path in
      Sqlite3.bind get_stmt 1 (Sqlite3.Data.INT (Int64.of_int prefix_type)) |> check_rc;
      Sqlite3.bind get_stmt 2 (Sqlite3.Data.TEXT suffix) |> check_rc;
      match Sqlite3.step get_stmt with
      | Sqlite3.Rc.DONE -> None
      | Sqlite3.Rc.ROW ->
        let file_info_blob = column_blob get_stmt 0 in
        Some (FileInfo.from_saved path (Marshal.from_string file_info_blob 0))
      | rc -> failwith (Printf.sprintf "Failure retrieving row: %s" (Sqlite3.Rc.to_string rc))

    let fold db ~init ~f =
      let iter_stmt = Sqlite3.prepare db iter_sqlite in
      let f iter_stmt acc =
        let prefix_int = column_int iter_stmt 0 in
        let suffix = column_str iter_stmt 1 in
        let file_info_blob = column_blob iter_stmt 2 in
        let relative_path = make_relative_path ~prefix_int ~suffix in
        let fi = FileInfo.from_saved relative_path (Marshal.from_string file_info_blob 0) in
        f relative_path fi acc
      in
      fold_sqlite iter_stmt ~f ~init
  end


  module TypesTable = struct
    let table_name = "NAMING_TYPES"
    let class_flag = Int64.of_int (type_of_type_to_enum TClass)
    let typedef_flag = Int64.of_int (type_of_type_to_enum TTypedef)

    let create_table_sqlite =
      Printf.sprintf "
        CREATE TABLE IF NOT EXISTS %s(
          HASH INTEGER PRIMARY KEY NOT NULL,
          CANON_HASH INTEGER NOT NULL,
          FLAGS INTEGER NOT NULL,
          FILE_INFO_PK INTEGER NOT NULL
        );
      " table_name

    let insert_sqlite =
      Printf.sprintf "
        INSERT INTO %s (HASH, CANON_HASH, FLAGS, FILE_INFO_PK) VALUES (?, ?, ?, ?);
      " table_name

    let (get_sqlite, get_sqlite_case_insensitive) =
      let base = Str.global_replace (Str.regexp "{table_name}") table_name "
        SELECT
          NAMING_FILE_INFO.PATH_PREFIX_TYPE,
          NAMING_FILE_INFO.PATH_SUFFIX,
          {table_name}.FLAGS
        FROM {table_name}
        LEFT JOIN NAMING_FILE_INFO ON
          {table_name}.FILE_INFO_PK = NAMING_FILE_INFO.PRIMARY_KEY
        WHERE {table_name}.{hash} = ?"
      in
      (Str.global_replace (Str.regexp "{hash}") "HASH" base,
        Str.global_replace (Str.regexp "{hash}") "CANON_HASH" base)

    let insert db ~name ~flags ~file_info_pk =
      let hash = SharedMem.get_hash name in
      let canon_hash = SharedMem.get_hash (to_canon_name_key name) in
      let insert_stmt = Sqlite3.prepare db insert_sqlite in
      Sqlite3.bind insert_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      Sqlite3.bind insert_stmt 2 (Sqlite3.Data.INT canon_hash) |> check_rc;
      Sqlite3.bind insert_stmt 3 (Sqlite3.Data.INT flags) |> check_rc;
      Sqlite3.bind insert_stmt 4 (Sqlite3.Data.INT file_info_pk) |> check_rc;
      Sqlite3.step insert_stmt |> check_rc;
      Sqlite3.finalize insert_stmt |> check_rc

    let insert_class db ~name ~file_info_pk =
      insert db ~name ~flags:class_flag ~file_info_pk

    let insert_typedef db ~name ~file_info_pk =
      insert db ~name ~flags:typedef_flag ~file_info_pk

    let get db ~name ~case_insensitive =
      let name = if case_insensitive then String.lowercase_ascii name else name in
      let hash = SharedMem.get_hash name in
      let get_sqlite = if case_insensitive then get_sqlite_case_insensitive else get_sqlite in
      let get_stmt = Sqlite3.prepare db get_sqlite in
      Sqlite3.bind get_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      match Sqlite3.step get_stmt with
      | Sqlite3.Rc.DONE -> None
      | Sqlite3.Rc.ROW ->
        let prefix_type = column_int get_stmt 0 in
        let suffix = column_str get_stmt 1 in
        let flags = Int64.to_int (column_int get_stmt 2) in
        let class_type = Core_kernel.Option.value_exn (type_of_type_of_enum flags) in
        Some (make_relative_path prefix_type suffix, class_type)
      | rc -> failwith (Printf.sprintf "Failure retrieving row: %s" (Sqlite3.Rc.to_string rc))
  end


  module FunsTable = struct
    let table_name = "NAMING_FUNS"

    let create_table_sqlite =
      Printf.sprintf "
        CREATE TABLE IF NOT EXISTS %s(
          HASH INTEGER PRIMARY KEY NOT NULL,
          CANON_HASH INTEGER NOT NULL,
          FILE_INFO_PK INTEGER NOT NULL
        );
      " table_name

    let insert_sqlite =
      Printf.sprintf "
        INSERT INTO %s (HASH, CANON_HASH, FILE_INFO_PK) VALUES (?, ?, ?);
      " table_name

    let (get_sqlite, get_sqlite_case_insensitive) =
      let base = Str.global_replace (Str.regexp "{table_name}") table_name "
        SELECT
          NAMING_FILE_INFO.PATH_PREFIX_TYPE,
          NAMING_FILE_INFO.PATH_SUFFIX
        FROM {table_name}
        LEFT JOIN NAMING_FILE_INFO ON
          {table_name}.FILE_INFO_PK = NAMING_FILE_INFO.PRIMARY_KEY
        WHERE {table_name}.{hash} = ?"
      in
      (Str.global_replace (Str.regexp "{hash}") "HASH" base,
        Str.global_replace (Str.regexp "{hash}") "CANON_HASH" base)

    let insert db ~name ~file_info_pk =
      let hash = SharedMem.get_hash name in
      let canon_hash = SharedMem.get_hash (to_canon_name_key name) in
      let insert_stmt = Sqlite3.prepare db insert_sqlite in
      Sqlite3.bind insert_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      Sqlite3.bind insert_stmt 2 (Sqlite3.Data.INT canon_hash) |> check_rc;
      Sqlite3.bind insert_stmt 3 (Sqlite3.Data.INT file_info_pk) |> check_rc;
      Sqlite3.step insert_stmt |> check_rc;
      Sqlite3.finalize insert_stmt |> check_rc

    let get db ~name ~case_insensitive =
      let name = if case_insensitive then String.lowercase_ascii name else name in
      let hash = SharedMem.get_hash name in
      let get_sqlite = if case_insensitive then get_sqlite_case_insensitive else get_sqlite in
      let get_stmt = Sqlite3.prepare db (get_sqlite) in
      Sqlite3.bind get_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      match Sqlite3.step get_stmt with
      | Sqlite3.Rc.DONE -> None
      | Sqlite3.Rc.ROW ->
        let prefix_type = column_int get_stmt 0 in
        let suffix = column_str get_stmt 1 in
        Some (make_relative_path prefix_type suffix)
      | rc -> failwith (Printf.sprintf "Failure retrieving row: %s" (Sqlite3.Rc.to_string rc))
  end


  module ConstsTable = struct
    let table_name = "NAMING_CONSTS"

    let create_table_sqlite =
      Printf.sprintf "
        CREATE TABLE IF NOT EXISTS %s(
          HASH INTEGER PRIMARY KEY NOT NULL,
          FILE_INFO_PK INTEGER NOT NULL
        );
      " table_name

    let insert_sqlite =
      Printf.sprintf "
        INSERT INTO %s (HASH, FILE_INFO_PK) VALUES (?, ?);
      " table_name

    let get_sqlite =
      Str.global_replace (Str.regexp "{table_name}") table_name "
        SELECT
          NAMING_FILE_INFO.PATH_PREFIX_TYPE,
          NAMING_FILE_INFO.PATH_SUFFIX
        FROM {table_name}
        LEFT JOIN NAMING_FILE_INFO ON
          {table_name}.FILE_INFO_PK = NAMING_FILE_INFO.PRIMARY_KEY
        WHERE {table_name}.HASH = ?
      "

    let insert db ~name ~file_info_pk =
      let hash = SharedMem.get_hash name in
      let insert_stmt = Sqlite3.prepare db insert_sqlite in
      Sqlite3.bind insert_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      Sqlite3.bind insert_stmt 2 (Sqlite3.Data.INT file_info_pk) |> check_rc;
      Sqlite3.step insert_stmt |> check_rc;
      Sqlite3.finalize insert_stmt |> check_rc

    let get db ~name =
      let hash = SharedMem.get_hash name in
      let get_stmt = Sqlite3.prepare db get_sqlite in
      Sqlite3.bind get_stmt 1 (Sqlite3.Data.INT hash) |> check_rc;
      match Sqlite3.step get_stmt with
      | Sqlite3.Rc.DONE -> None
      | Sqlite3.Rc.ROW ->
        let prefix_type = column_int get_stmt 0 in
        let suffix = column_str get_stmt 1 in
        Some (make_relative_path prefix_type suffix)
      | rc -> failwith (Printf.sprintf "Failure retrieving row: %s" (Sqlite3.Rc.to_string rc))
  end


  module Database_handle : sig
    val set_db_path : string -> unit
    val is_connected : unit -> bool
    val get_db : unit -> Sqlite3.db option
  end  = struct

    module Shared_db_settings = SharedMem.NoCache
      (SharedMem.ProfiledImmediate)
      (StringKey)
      (struct
        type t = string
        let prefix = Prefix.make()
        let description = "NamingTableDatabaseSettings"
      end)

    let check_table_sqlite =
      "SELECT NAME FROM SQLITE_MASTER WHERE TYPE='table' AND NAME='NAMING_FILE_INFO'"

    let open_db () =
      match Shared_db_settings.get "database_path" with
      | None -> None
      | Some path ->
        let db = Sqlite3.db_open path in
        let has_table = ref false in
        Sqlite3.exec db ~cb:(fun _ _ -> has_table := true) check_table_sqlite |> check_rc;
        if !has_table
        then Some db
        else failwith @@ Printf.sprintf "Database %s does not have a naming table." path

    let db = ref (lazy (open_db ()))

    let set_db_path path =
      Shared_db_settings.add "database_path" path;
      (* Force this immediately so that we can get validation errors in master. *)
      db := Lazy.from_val (open_db ())

    let get_db () =
      Lazy.force !db

    let is_connected () =
      get_db () <> None
  end


  let save_file_info db file_info_pk relative_path file_info =
    let open Core_kernel in
    FileInfoTable.insert db file_info_pk relative_path file_info;
    let symbols_inserted = 0 in
    let symbols_inserted = List.fold
      ~init:symbols_inserted
      ~f:(fun acc (_, name) -> FunsTable.insert db ~name ~file_info_pk; acc + 1)
      file_info.FileInfo.funs
    in
    let symbols_inserted = List.fold
      ~init:symbols_inserted
      ~f:(fun acc (_, name) -> TypesTable.insert_class db ~name ~file_info_pk; acc + 1)
      file_info.FileInfo.classes
    in
    let symbols_inserted = List.fold
      ~init:symbols_inserted
      ~f:(fun acc (_, name) -> TypesTable.insert_typedef db ~name ~file_info_pk; acc + 1)
      file_info.FileInfo.typedefs
    in
    let symbols_inserted = List.fold
      ~init:symbols_inserted
      ~f:(fun acc (_, name) -> ConstsTable.insert db ~name ~file_info_pk; acc + 1)
      file_info.FileInfo.consts
    in
    symbols_inserted

  let create_database db_name f =
    let db = Sqlite3.db_open db_name in
    Sqlite3.exec db "PRAGMA synchronous = OFF;" |> check_rc;
    Sqlite3.exec db "PRAGMA journal_mode = MEMORY;" |> check_rc;
    Sqlite3.exec db "BEGIN TRANSACTION;" |> check_rc;
    Sqlite3.exec db FileInfoTable.create_table_sqlite |> check_rc;
    Sqlite3.exec db ConstsTable.create_table_sqlite |> check_rc;
    Sqlite3.exec db TypesTable.create_table_sqlite |> check_rc;
    Sqlite3.exec db FunsTable.create_table_sqlite |> check_rc;
    let () = f (save_file_info db) in
    Sqlite3.exec db "END TRANSACTION;" |> check_rc;
    if not (Sqlite3.db_close db)
    then failwith (Printf.sprintf "Could not close database '%s'" db_name)

  let set_db_path = Database_handle.set_db_path
  let is_connected = Database_handle.is_connected

  let fold ~init ~f ~local_changes =
    (* We depend on [Relative_path.Map.bindings] returning results in increasing
     * order here. *)
    let sorted_changes = Relative_path.Map.bindings local_changes in

    (* This function looks kind of funky, but it's not too terrible when
     * explained. We essentially have two major inputs:
     *   1. a path and file info that we got from SQLite. In order for this
     *      function to work properly, we require that consecutive invocations
     *      of this function within the same [fold] call have paths that are
     *      strictly increasing.
     *   2. the list of local changes. This list is also required to be in
     *      increasing sorted order.
     * In order to make sure that we a) return results in sorted order, and
     * b) properly handle files that have been added (and therefore will never
     * show up in the [path] and [fi] args), we essentially walk both lists in
     * sorted order (walking the SQLite list through successive invocations and
     * walking the local changes list through recursion), at each step folding
     * over whichever entry has the lowest sort order. If both paths are
     * identical, we use the one from our local changes. In this way we get O(n)
     * iteration while handling additions, modifications, and deletions
     * properly (again, given our input sorting restraints). *)
    let rec consume_sorted_changes path fi (sorted_changes, acc) =
      match sorted_changes with
      | hd :: tl when fst hd < path ->
        begin match snd hd with
        | Modified local_fi -> consume_sorted_changes path fi (tl, (f (fst hd) local_fi acc))
        | Deleted -> consume_sorted_changes path fi (tl, acc)
        end
      | hd :: tl when fst hd = path ->
        begin match snd hd with
        | Modified fi -> (tl, f path fi acc)
        | Deleted -> (tl, acc)
        end
      | _ -> (sorted_changes, f path fi acc)
    in
    let db = match Database_handle.get_db () with
      | Some db -> db
      | None -> failwith "Attempted to access non-connected database"
    in
    let (remaining_changes, acc) =
      FileInfoTable.fold db ~init:(sorted_changes, init) ~f:consume_sorted_changes
    in
    List.fold_left begin fun acc (path, delta) ->
      match delta with
      | Modified fi -> f path fi acc
      | Deleted -> (* This probably shouldn't happen? *) acc
    end acc remaining_changes

  let get_file_info path =
    match Database_handle.get_db () with
    | None -> None
    | Some db ->
      FileInfoTable.get_file_info db path

  let get_type_pos name ~case_insensitive =
    match Database_handle.get_db () with
    | None -> None
    | Some db ->
      TypesTable.get db ~name ~case_insensitive

  let get_fun_pos name ~case_insensitive =
    match Database_handle.get_db () with
    | None -> None
    | Some db ->
      FunsTable.get db ~name ~case_insensitive

  let get_const_pos name =
    match Database_handle.get_db () with
    | None -> None
    | Some db ->
      ConstsTable.get db ~name
end

let set_sqlite_fallback_path = Sqlite.set_db_path


(*****************************************************************************)
(* Forward naming table functions *)
(*****************************************************************************)


let empty = Unbacked Relative_path.Map.empty

let filter a ~f =
  match a with
  | Unbacked a -> Unbacked (Relative_path.Map.filter a f)
  | Backed local_changes ->
    Backed (Sqlite.fold ~init:local_changes ~f:begin fun path fi acc ->
      if f path fi then acc else Relative_path.Map.add acc ~key:path ~data:Deleted
    end ~local_changes)

let fold a ~init ~f =
  match a with
  | Unbacked a -> Relative_path.Map.fold a ~init ~f
  | Backed local_changes -> Sqlite.fold ~init ~f ~local_changes

let get_files a =
  match a with
  | Unbacked a -> Relative_path.Map.keys a
  | Backed local_changes ->
    (* Reverse at the end to preserve ascending sort order. *)
    Sqlite.fold ~init:[] ~f:(fun path _ acc -> path :: acc) ~local_changes
    |> List.rev

let get_file_info a key =
  match a with
  | Unbacked a -> Relative_path.Map.get a key
  | Backed local_changes ->
    match Relative_path.Map.get local_changes key with
    | Some (Modified fi) -> Some fi
    | Some Deleted -> None
    | None -> Sqlite.get_file_info key

let get_file_info_unsafe a key =
  Core_kernel.Option.value_exn (get_file_info a key)

let has_file a key =
  match get_file_info a key with
  | Some _ -> true
  | None -> false

let iter a ~f =
  match a with
  | Unbacked a -> Relative_path.Map.iter a ~f
  | Backed local_changes -> Sqlite.fold ~init:() ~f:(fun path fi () -> f path fi) ~local_changes

let update a key data =
  match a with
  | Unbacked a -> Unbacked (Relative_path.Map.add a ~key ~data)
  | Backed local_changes -> Backed (Relative_path.Map.add local_changes ~key ~data:(Modified data))

let update_many a updates =
  match a with
  | Unbacked a ->
    (* Reverse the order because union always takes the first value. *)
    Unbacked (Relative_path.Map.union updates a)
  | Backed local_changes ->
    let local_updates = Relative_path.Map.map updates ~f:(fun data -> Modified data) in
    Backed (Relative_path.Map.union local_updates local_changes)

let combine a b =
  match b with
  | Unbacked b ->
    update_many a b
  | _ -> failwith "SQLite-backed naming tables cannot be the second argument to combine."

let save naming_table db_name =
  let t = Unix.gettimeofday() in
  let files_added = ref 0 in
  let symbols_added = ref 0 in
  Sqlite.create_database db_name begin fun save_file_info ->
    let get_next_file_info_primary_key () =
      incr files_added;
      !files_added
    in
    iter naming_table begin fun path file_info ->
      let file_info_primary_key = Int64.of_int (get_next_file_info_primary_key ()) in
      let new_symbol_count = save_file_info file_info_primary_key path file_info in
      symbols_added := !symbols_added + new_symbol_count
    end
  end;
  let _ : float =
    Hh_logger.log_duration
      (Printf.sprintf "Inserted %d files and %d symbols" !files_added !symbols_added)
      t
  in
  ()


(*****************************************************************************)
(* Creation functions *)
(*****************************************************************************)


let create a =
  Unbacked a

let from_db () =
  if not (Sqlite.is_connected ())
  then failwith "Cannot create a backed database without a SQLite connection."
  else Backed Relative_path.Map.empty


(*****************************************************************************)
(* Conversion functions *)
(*****************************************************************************)


let from_saved saved =
  Unbacked (Relative_path.Map.fold saved ~init:Relative_path.Map.empty ~f:(fun fn saved acc ->
    let file_info = FileInfo.from_saved fn saved in
    Relative_path.Map.add acc fn file_info
  ))

let to_saved a =
  match a with
  | Unbacked a ->
    Relative_path.Map.map a FileInfo.to_saved
  | Backed _ -> failwith "Converting a backed naming table to saved is not supported."

let to_fast a =
  match a with
  | Unbacked a ->
    Relative_path.Map.map a FileInfo.simplify
  | Backed _ -> failwith "Converting a backed naming table to a FAST is not supported."

let saved_to_fast saved =
  Relative_path.Map.map saved FileInfo.saved_to_names


(*****************************************************************************)
(* Reverse naming table functions *)
(*****************************************************************************)


let check_valid key pos =
  if FileInfo.get_pos_filename pos = Relative_path.default then begin
    Hh_logger.log
      ("WARNING: setting canonical position of %s to be in dummy file. If this \
      happens in incremental mode, things will likely break later.") key;
    Hh_logger.log "%s"
      (Printexc.raw_backtrace_to_string (Printexc.get_callstack 100));
  end

type blocked_entry = Blocked

(** Gets an entry from shared memory, or falls back to SQLite if necessary. If data is returned by
    SQLite, we also cache it back to shared memory.

    @param map_result function that maps from the SQLite fallback value to the actual value type we
      want to cache and return.
    @param get_func function that retrieves a key from shared memory.
    @param check_block_func function that checks if a key is blocked from falling back to SQLite.
    @param fallback_get_func function to get a fallback value from SQLite.
    @param add_func function to cache a value back into shared memory.
    @param measure_name the name of the measure to use for tracking fallback stats. We write a 1.0
      if the request could be resolved entirely from shared memory, and 0.0 if we had to go to
      SQLite.
    @param key the key to request.
*)
let get_and_cache
  ~(map_result : 'fallback_value -> 'value)
  ~(get_func : 'key -> 'value option)
  ~(check_block_func : 'key -> blocked_entry option)
  ~(fallback_get_func : 'key -> 'fallback_value option)
  ~(add_func : 'key -> 'value -> unit)
  ~(measure_name : string)
  ~(key : 'key)
: 'value option =
  match get_func key with
  | Some v ->
    Measure.sample measure_name 1.0;
    Some v
  | None ->
    if not (Sqlite.is_connected ()) then None else
    begin match check_block_func key with
    | Some Blocked ->
      (* We sample 1.0 here even though we're returning None because we didn't go to SQLite. *)
      Measure.sample measure_name 1.0;
      None
    | None ->
      Measure.sample measure_name 0.0;
      begin match fallback_get_func key with
      | Some res ->
        let pos = map_result res in
        add_func key pos;
        Some pos
      | None ->
        None
      end
    end


module type ReverseNamingTable = sig
  type pos

  val add : string -> pos -> unit
  val get_pos : ?bypass_cache:bool -> string -> pos option
  val remove_batch : SSet.t -> unit

  val heap_string_of_key : string -> string
end

(* The Types module records both class names and typedefs since they live in the
* same namespace. That is, one cannot both define a class Foo and a typedef Foo
* (or FOO or fOo, due to case insensitivity). *)
module Types = struct
  type pos = FileInfo.pos * type_of_type

  module TypeCanonHeap = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = string
      let prefix = Prefix.make()
      let description = "TypeCanon"
    end)

  module TypePosHeap = SharedMem.WithCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = pos
      let prefix = Prefix.make ()
      let description = "TypePos"
    end)

  module BlockedEntries = SharedMem.WithCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = blocked_entry
      let prefix = Prefix.make()
      let description = "TypeBlocked"
    end)

  let add id type_info =
    if not @@ TypePosHeap.LocalChanges.has_local_changes () then check_valid id (fst type_info);
    TypeCanonHeap.add (to_canon_name_key id) id;
    TypePosHeap.write_around id type_info

  let get_pos ?(bypass_cache=false) id =
    let get_func =
      if bypass_cache
      then TypePosHeap.get_no_cache
      else TypePosHeap.get
    in
    let map_result (path, entry_type) =
      let name_type = match entry_type with
        | TClass -> FileInfo.Class
        | TTypedef -> FileInfo.Typedef
      in
      (FileInfo.File (name_type, path), entry_type)
    in
    get_and_cache
      ~map_result
      ~get_func
      ~check_block_func:BlockedEntries.get
      ~fallback_get_func:(Sqlite.get_type_pos ~case_insensitive:false)
      ~add_func:add
      ~measure_name:"Reverse naming table (types) cache hit rate"
      ~key:id

  let get_canon_name id =
    let open Core_kernel in
    let map_result (path, entry_type) =
      let _path_str = Relative_path.S.to_string path in
      let id = match entry_type with
        | TClass ->
          let class_opt = Ast_provider.find_class_in_file_nast ~case_insensitive:true path id in
          (Option.value_exn class_opt).Nast.c_name
        | TTypedef ->
          let typedef_opt = Ast_provider.find_typedef_in_file_nast ~case_insensitive:true path id in
          (Option.value_exn typedef_opt).Nast.t_name
      in
      snd id
    in
    get_and_cache
      ~map_result
      ~get_func:TypeCanonHeap.get
      ~check_block_func:BlockedEntries.get
      ~fallback_get_func:(Sqlite.get_type_pos ~case_insensitive:true)
      ~add_func:TypeCanonHeap.add
      ~measure_name:"Canon naming table (types) cache hit rate"
      ~key:id

  let remove_batch types =
    let canon_key_types = canonize_set types in
    TypeCanonHeap.remove_batch canon_key_types;
    TypePosHeap.remove_batch types;
    if Sqlite.is_connected ()
    then SSet.iter (fun id -> BlockedEntries.add id Blocked) (SSet.union types canon_key_types)

  let heap_string_of_key = TypePosHeap.string_of_key
end

module Funs = struct
  type pos = FileInfo.pos

  module FunCanonHeap = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = string
      let prefix = Prefix.make()
      let description = "FunCanon"
    end)

  module FunPosHeap = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = pos
      let prefix = Prefix.make()
      let description = "FunPos"
    end)

  module BlockedEntries = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = blocked_entry
      let prefix = Prefix.make()
      let description = "FunBlocked"
    end)

  let add id pos =
    if not @@ FunPosHeap.LocalChanges.has_local_changes () then check_valid id pos;
    FunCanonHeap.add (to_canon_name_key id) id;
    FunPosHeap.add id pos

  let get_pos ?bypass_cache:(_=false) id =
    let map_result path = FileInfo.File (FileInfo.Fun, path) in
    get_and_cache
      ~map_result
      ~get_func:FunPosHeap.get
      ~check_block_func:BlockedEntries.get
      ~fallback_get_func:(Sqlite.get_fun_pos ~case_insensitive:false)
      ~add_func:add
      ~measure_name:"Reverse naming table (functions) cache hit rate"
      ~key:id

  let get_canon_name name =
    let open Core_kernel in
    let map_result path =
      let fun_opt = Ast_provider.find_fun_in_file_nast ~case_insensitive:true path name in
      snd (Option.value_exn fun_opt).Nast.f_name
    in
    get_and_cache
      ~map_result
      ~get_func:FunCanonHeap.get
      ~check_block_func:BlockedEntries.get
      ~fallback_get_func:(Sqlite.get_fun_pos ~case_insensitive:true)
      ~add_func:FunCanonHeap.add
      ~measure_name:"Canon naming table (functions) cache hit rate"
      ~key:name

  let remove_batch funs =
    let canon_key_funs = canonize_set funs in
    FunCanonHeap.remove_batch canon_key_funs;
    FunPosHeap.remove_batch funs;
    if Sqlite.is_connected ()
    then SSet.iter (fun id -> BlockedEntries.add id Blocked) (SSet.union funs canon_key_funs)

  let heap_string_of_key = FunPosHeap.string_of_key
end

module Consts = struct
  type pos = FileInfo.pos

  module ConstPosHeap = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = pos
      let prefix = Prefix.make()
      let description = "ConstPos"
    end)

  module BlockedEntries = SharedMem.NoCache
    (SharedMem.ProfiledImmediate)
    (StringKey)
    (struct
      type t = blocked_entry
      let prefix = Prefix.make()
      let description = "ConstBlocked"
    end)

  let add id pos =
    if not @@ ConstPosHeap.LocalChanges.has_local_changes () then check_valid id pos;
    ConstPosHeap.add id pos

  let get_pos ?bypass_cache:(_=false) id =
    let map_result path = FileInfo.File (FileInfo.Const, path) in
    get_and_cache
      ~map_result
      ~get_func:ConstPosHeap.get
      ~check_block_func:BlockedEntries.get
      ~fallback_get_func:Sqlite.get_const_pos
      ~add_func:add
      ~measure_name:"Reverse naming table (consts) cache hit rate"
      ~key:id

  let remove_batch consts =
    ConstPosHeap.remove_batch consts;
    if Sqlite.is_connected ()
    then SSet.iter (fun id -> BlockedEntries.add id Blocked) consts

  let heap_string_of_key = ConstPosHeap.string_of_key
end

let push_local_changes () =
  Types.TypePosHeap.LocalChanges.push_stack ();
  Types.TypeCanonHeap.LocalChanges.push_stack ();
  Types.BlockedEntries.LocalChanges.push_stack ();
  Funs.FunPosHeap.LocalChanges.push_stack ();
  Funs.FunCanonHeap.LocalChanges.push_stack ();
  Funs.BlockedEntries.LocalChanges.push_stack ();
  Consts.ConstPosHeap.LocalChanges.push_stack ();
  Consts.BlockedEntries.LocalChanges.push_stack ()

let pop_local_changes () =
  Types.TypePosHeap.LocalChanges.pop_stack ();
  Types.TypeCanonHeap.LocalChanges.pop_stack ();
  Types.BlockedEntries.LocalChanges.pop_stack ();
  Funs.FunPosHeap.LocalChanges.pop_stack ();
  Funs.FunCanonHeap.LocalChanges.pop_stack ();
  Funs.BlockedEntries.LocalChanges.pop_stack ();
  Consts.ConstPosHeap.LocalChanges.pop_stack ();
  Consts.BlockedEntries.LocalChanges.pop_stack ()

let has_local_changes () =
  Types.TypePosHeap.LocalChanges.has_local_changes ()
  || Types.TypeCanonHeap.LocalChanges.has_local_changes ()
  || Types.BlockedEntries.LocalChanges.has_local_changes ()
  || Funs.FunPosHeap.LocalChanges.has_local_changes ()
  || Funs.FunCanonHeap.LocalChanges.has_local_changes ()
  || Funs.BlockedEntries.LocalChanges.has_local_changes ()
  || Consts.ConstPosHeap.LocalChanges.has_local_changes ()
  || Consts.BlockedEntries.LocalChanges.has_local_changes ()


(*****************************************************************************)
(* Testing functions *)
(*****************************************************************************)


let assert_is_backed a backed =
  match a with
  | Unbacked _ -> assert (not backed)
  | Backed _ -> assert backed
