:- module(database,[
          ]).

/** <module> Implementation of database graph management
 *
 * This module helps other modules with the representation of databases and
 * their associated graphs by bundling them as objects with some convenience
 * operators and accessors.
 *
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, under version 3 of the License.        *
 *                                                                       *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- use_module(utils).
:- use_module(types).
:- use_module(sdk).
:- use_module(file_utils).
:- use_module(triplestore).

:- use_module(library(prolog_stack)).
:- use_module(library(apply)).
:- use_module(library(apply_macros)).

:- op(2, xfx, ^^).

/*
 * Types:
 *
 * graph_descriptor --> named_graph{ name : atom }
 *                    | ref_graph{ layer_id : atom }
 *
 * A named_graph refers to a file in the store - this has to be made unique so we don't get
 * collisions between different databases. Currently only used for the terminus and database graph
 * - one per repository. This uses the file label mechanism.
 *
 * A ref_graph is a layer id that can be resolved to a graph.
 *
 * collection_descriptor --> terminus_descriptor
 *                         | database_descriptor{ database_name : uri,
 *                                                instance : list(graph_descriptor)}
 *                         | repository_descriptor{ database_descriptor : database_descriptor,
 *                                                  repository_name : uri,
 *                                                  instance : list(graph_descriptor)}
 *                         | ref_descriptor{ repository_descriptor: repository_descriptor,
 *                                           ref_name : uri, % the name of the thing advancing
 *                                           last_commit : uri, % the base of the commit
 *                                           author : string,
 *                                           message : string,
 *                                           schema : list(graph_descriptor)
 *                                           instance : list(graph_descriptor)
 *                                           inference : list(graph_descriptor)}
 *
 * terminus_descriptor: refers to the core database with user and database management.
 * This database refers to the various database descriptors which can be opened "by name"
 * using the label mechanism.
 *
 * database_descriptor: is a per database graph collections that store information about all
 * local and remotes which exist
 *
 * repository descriptors: is used to refer to the branchs that exist in a given repository.
 *
 * branch_descriptors: refers to the precise graph collection which is a 'normal' database
 * object used in WOQL.
 *
 * Transaction management requires that we advance a file system label associated with the
 * repository descriptor when we have performed a full transaction. All other multi-graph
 * management is done within the graphs associated with the repository descriptor.
 *
 * The type polymorphism is designed to allow WOQL read transactions to work identically over
 * all of these cases. However, *write* transactions have to be done differently on each of
 * these by case, though triple writes can be done identically.
 *
 * read_obj ---> read_obj{ descriptor : graph_descriptor, read : Layer}
 * write_obj ---> write_obj{ descriptor : graph_descriptor, write : Layer_Builder}
 * query_object ---> query_object{ descriptor : collection_descriptor,
 *                                 <parent : query_object>, % except for database/terminus descriptors
 *                                 <commit_author : string>, % only ref_descriptors
 *                                 <commit_message : string>, % only ref_descriptors
 *                                 instance_read_objects : list(read_obj),
 *                                 schema_read_objects : list(read_obj),
 *                                 inference_read_objects : list(read_obj),
 *                                 instance_write_objects : list(write_obj),
 *                                 schema_write_objects : list(write_obj),
 *                                 inference_write_objects : list(write_obj) }
 *
 * transaction_object ---> transaction_object{ collection_descriptors : list(collection_descriptor),
 *                                             query_objs : list(query_objs),
 *                                             post_objs : list(query_objs) }
 */


/*
 * terminus_repository_schema(Schema) is det.
 *
 * Returns the name of the repository schema
 */
terminus_repository_schema(Schema) :-
    db_path(Path),
    www_form_encode('terminus-repository-schema',Safe_GID),
    interpolate([Path,Safe_GID,'.label'],Schema).

/**
 * open_read_obj(Graph_Descriptor : graph_descriptor, Read_Object : read_object) is det.
 *
 * opens a graph descriptor with a querable read object.
 */
open_read_obj(Graph, read_obj{ descriptor : Graph, read : Layer }) :-
    Graph = named_graph{ name : Name },
    storage(Store),
    safe_open_named_graph(Store,Name,Obj),
    head(Obj,Layer).
open_read_obj(Graph, read_obj{ descriptor : Graph, read : Layer }) :-
    Graph = ref_graph{ layer_id : Layer_ID },
    storage(Store),
    store_id_layer(Store,Layer_ID,Layer).

/**
 * open_write_obj(Graph_Descriptor : graph_descriptor, Write_Object : write_object) is det.
 *
 * opens a graph descriptor with a writer builder.
 */
open_write_obj(Graph, write_obj{ descriptor : Graph, write : Layer_Builder }) :-
    Graph = named_graph{ name : Name },
    storage(Store),
    safe_open_named_graph(Store,Name,Obj),
    open_write(Obj,Layer_Builder).
open_write_obj(Graph, write_obj{ descriptor : Graph, write : Layer_Builder }) :-
    Graph = ref_graph{ layer_id : Layer_ID },
    storage(Store),
    store_id_layer(Store,Layer_ID,Layer),
    open_write(Layer,Layer_Builder).

included_read_objects(Graph_Descriptors, Read_Graph_Descriptors, Read_Objects) :-
    include({Read_Graph_Descriptors}/[X]>>memberchk(X,Read_Graph_Descriptors),
            Graph_Descriptors,
            Read_Descriptors),
    maplist([Descriptor,Read_Obj]>>open_read_obj(Descriptor,Read_Obj),
            Read_Descriptors, Read_Objects).

included_write_objects(Graph_Descriptors, Read_Graph_Descriptors, Read_Objects) :-
    include({Read_Graph_Descriptors}/[X]>>memberchk(X,Read_Graph_Descriptors),
            Graph_Descriptors,
            Read_Descriptors),
    maplist([Descriptor,Read_Obj]>>open_write_obj(Descriptor,Read_Obj),
            Read_Descriptors, Read_Objects).

/**
 * descriptor_query(Descriptor, Read_Graph_Descriptors, Write_Graph_Descriptors, Map, New_Map) is det.
 *
 * Impements the logic which allows us to special-case the
 * opening of descriptors for repository, branch and graph.
 *
 * It opens descriptors like an onion, avoiding duplicate opens with a Map.
 *
 * @Descriptor has type collection_descriptor
 * @Read_Graph_Descriptor has type list(collection_descriptor)
 *                        This specifies which read queries to open.
 * @Write_Graph_Descriptor has type list(collection_descriptor)
 *                         This specifies which write queries to open.
 * @Map has type list(descriptor=query_object)
 *      Keeps track of the descriptors which have already been opened so we are monotonic
 * @New_Map has type list(descriptor=query_object)
 *      Updated map
 */
descriptor_query(Descriptor, Read_Graph_Descriptors, Write_Graph_Descriptors, Map, Map) :-
    memberchk(Descriptor=_, Map),
    !.
descriptor_query(terminus_descriptor, Read_Graph_Descriptors, Write_Graph_Descriptors, Map,
                 [terminus_descriptor=Query_Object|Map]) :-

    terminus_schema(Schema_Name),
    Schema_Graph = named_graph{ name : Schema_Name },

    terminus_instance(Instance_Name),
    Instance_Graph = named_graph{ name : Instance_Name },

    terminus_instance(Instance_Name),
    Inference_Graph = named_graph{ name : Inference_Name },

    % Get hard coded schema read/write objects
    include_read_objects([Schema_Graph],Read_Graph_Descriptors, Schema_Read_Objects),
    include_write_objects([Schema_Graph],Write_Graph_Descriptors, Schema_Write_Objects),

    % Get hard coded instance read/write objects
    include_read_objects([Instance_Graph],Read_Graph_Descriptors,Instance_Read_Objects),
    include_write_objects([Instance_Graph],Write_Graph_Descriptors, Instance_Write_Objects),

    % Get hard coded inference read/write objects
    include_read_objects([Inference_Graph],Read_Graph_Descriptors,Inference_Read_Objects),
    include_write_objects([Inference_Graph],Write_Graph_Descriptors,Inference_Write_Objects),

    Query_Object = query_obj{
                       descriptor : Collection_Descriptor,
                       instance_read_objects : Instance_Read_Objects,
                       schema_read_objects : Schema_Read_Objects,
                       inference_read_objects : Inference_Read_Objects,
                       instance_write_objects : Instance_Write_Objects,
                       inference_write_objects : Inference_Write_Objects,
                       schema_write_objects : Schema_Write_Objects
                   }.
descriptor_query(Descriptor, Read_Graph_Descriptors, Write_Graph_Descriptors, Map,
                 [Descriptor=Query_Object|Map]) :-
    Descriptor = database_descriptor{
                     database_name : DB_Name,
                     instance : IL
                 },
    !,
    layer_ontology(Layer_Ontology_Name),
    Layer_Ontology_Graph = named_graph{ name : Layer_Ontology_Name },
    repository_ontology(Repository_Ontology_Name),
    Repository_Ontology_Graph = named_graph{ name : Repository_Ontology_Name },

    % Get hard coded layer and repository schema read/write objects
    Schema_Graphs = [Repository_Ontology_Graph, Layer_Ontology_Graph],
    include_read_objects(Schema_Graphs,Read_Graph_Descriptors, Read_Schema_Objects),
    include_write_objects(Schema_Graphs,Write_Graph_Descriptors, Write_Schema_Objects),

    % Get instance read/write objects
    include_read_objects(IL,Read_Graph_Descriptors,Read_Instance_Objects),
    include_write_objects(IL,Write_Graph_Descriptors, Write_Instance_Objects),

    Query_Object = query_obj{
                       descriptor : Collection_Descriptor,
                       instance_read_objects : Instance_Read_Objects,
                       schema_read_objects : Schema_Read_Objects,
                       inference_read_objects : [],
                       instance_write_objects : Write_Instance_Objects,
                       inference_write_objects : [],
                       schema_write_objects : Schema_Write_Objects
                   }.
descriptor_query(Repository, Read_Mask, Write_Mask, Map,
                 [Descriptor=Query_Object|New_Map]) :-
    Descriptor = repository_descriptor{
                     database_descriptor : DB,
                     repository_name : _Name,
                     author : Author,
                     message : Message,
                     instance : IL
                 },
    !,
    descriptor_query(DB, Read_Mask, Write_Mask, Map, New_Map),
    memberchk(DB,New_Map, Parent_Query_Obj),

    layer_ontology(Layer_Ontology_Name),
    Layer_Ontology_Graph = named_graph{ name : Layer_Ontology_Name },
    ref_ontology(Ref_Ontology_Name),
    Repository_Ontology_Graph = named_graph{ name : Repository_Ontology_Name },

    % Get hard coded layer and repository schema read/write objects
    Schema_Graphs = [Ref_Ontology_Graph, Layer_Ontology_Graph],
    include_read_objects(Schema_Graphs,Read_Graph_Descriptors, Read_Schema_Objects),
    include_write_objects(Schema_Graphs,Write_Graph_Descriptors, Write_Schema_Objects),

    % Get instance read/write objects
    include_read_objects(IL,Read_Graph_Descriptors,Read_Instance_Objects),
    include_write_objects(IL,Write_Graph_Descriptors, Write_Instance_Objects),

    Query_Object = query_obj{
                       parent : Parent_Query_Obj,
                       descriptor : Descriptor,
                       instance_read_objects : Read_Instance_Objects,
                       schema_read_objects : Read_Schema_Objects,
                       inference_read_objects : [],
                       instance_write_objects : Write_Instance_Objects,
                       schema_write_objects : Write_Schema_Objects,
                       inference_write_objects : []
                   }.
descriptor_query(Descriptor, Read_Mask, Write_Mask, Map,
                 [Descriptor=Query_Object|New_Map]) :-
    Descriptor = ref_descriptor{ repository_descriptor : Repository_Descriptor,
                                 ref_name : Ref_Name,
                                 last_commit : Last_Commit,
                                 repository_name : Repository_Name,
                                 author : Author,
                                 message : Message,
                                 schema : Schema_List,
                                 inference : Inf_List,
                                 instance : Instance_List },
    !,
    descriptor_query(Repository_Descriptor, Read_Mask, Write_Mask, Map, New_Map),
    memberchk(Repository_Descriptor, New_Map, Parent_Query_Obj),

    % Get schema read/write objects
    include_read_objects(Schema_Graphs,Read_Graph_Descriptors, Schema_Read_Objects),
    include_write_objects(Schema_Graphs,Write_Graph_Descriptors, Schema_Write_Objects),

    % Get instance read/write objects
    include_read_objects(Instance_List,Read_Graph_Descriptors, Instance_Read_Objects),
    include_write_objects(Instance_List,Write_Graph_Descriptors, Instance_Write_Objects),

    % Get inference read/write objects
    include_read_objects(Inference_List,Read_Graph_Descriptors, Inference_Read_Objects),
    include_write_objects(Inference_List,Write_Graph_Descriptors, Inference_Write_Objects),

    Query_Obj = query_obj{
                    parent : Parent_Query_Obj,
                    descriptor : Descriptor,
                    commit_message : Message,
                    commit_author : Author,
                    instance_read_objects : Instance_Read_Objects,
                    schema_read_objects : Schema_Read_Objects,
                    inference_read_objects : Inference_Read_Objects,
                    instance_write_objects : Instance_Write_Objects,
                    schema_write_objects : Schema_Write_Objects,
                    inference_write_objects : Inference_Write_Objects
                }.

update_read_objects([], New_Read_Objects, New_Read_Objects).
update_read_objects([Old_Read_Object|Old_Read_Objects], New_Read_Objects, Results) :-
    memberchk(read_obj{ descriptor: Old_Read_Object.descriptor, read: _}, New_Read_Objects),
    !,
    update_read_objects(Old_Read_Objects, New_Read_Objects, Results).
update_read_objects([Old_Read_Object|Old_Read_Objects], New_Read_Objects, [Old_Read_Object|Results]) :-
    update_read_objects(Old_Read_Objects, New_Read_Objects, Results).

commit_write_object(write_obj{
                       descriptor: Graph_Descriptor,
                       write: Layer_Builder
                   },
                    read_obj{
                        descriptor: Graph_Descriptor,
                        read: Layer
                    }) :-
    terminus_store:nb_commit(Layer_Builder, Layer).

/* TODO: This seems completely wrong. Probably need to use 'put' due to polymorphism */
commit_query_object(query_object{
                        collection_descriptor: Collection_Descriptor,
                        instance_read_objects: Instance_Read_Objects,
                        inference_read_objects: Inference_Read_Objects,
                        schema_read_objects: Schema_Read_Objects,
                        instance_write_objects: Instance_Write_Objects,
                        inference_write_objects: Inference_Write_Objects,
                        schema_write_objects: Schema_Write_Objects
                    },
                    query_object {
                        collection_descriptor: Collection_Descriptor,
                        instance_read_objects: New_Instance_Read_Objects,
                        inference_read_objects: New_Inference_Read_Objects,
                        schema_read_objects: New_Schema_Read_Objects,
                        instance_write_objects: [],
                        inference_write_objects: [],
                        schema_write_objects: []
                        }) :-
    maplist(commit_write_object,
            Instance_Write_Objects,
            Committed_Instance_Objects),
    maplist(commit_write_object,
            Schema_Write_Objects,
            Committed_Schema_Objects),
    maplist(commit_write_object,
            Inference_Write_Objects,
            Committed_Inference_Objects),

    update_read_objects(Instance_Read_Objects, Committed_Instance_Objects, New_Instance_Read_Objects),
    update_read_objects(Schema_Read_Objects, Committed_Schema_Objects, New_Schema_Read_Objects),
    update_read_objects(Inference_Read_Objects, Committed_Inference_Objects, New_Inference_Read_Objects).

die(Message) :-
    throw(not_acceptable(_{'terminus:status': 'terminus:error',
                           'terminus:message': Message
                          })).

:- meta_predicate call_or_die(:, +).
call_or_die(Call, Message) :-
    (   call(Call)
    ->  true
    ;   die(Message)).


/**
 * open_descriptor_queries_uniquely(Descriptors, Read_Descriptors, Write_Descriptors, Query_Objects, Map) is det.
 *
 * Only creates one object per descriptor - actually a fold.
 */
open_descriptor_queries_uniquely([], _Read_Descriptors, _Write_Descriptors, [], _Map).
open_descriptor_queries_uniquely([Descriptor|Descriptors], Read_Descriptors, Write_Descriptors,
                                 Query_Objects, Map) :-
    descriptor_query(Descriptor, Read_Descriptors, Write_Descriptors,
                     Descriptor_Query_Objects, Map, New_Map),
    % difference list anyone?
    append(Descriptor_Query_Objects,New_Query_Objects,Query_Objects),
    open_descriptor_queries_uniquely(Descriptors, Read_Descriptors,
                                     Write_Descriptors, New_Query_Objects, New_Map).

key_equal((=), X=_, X=_).
key_equal((<), X=_, Y=_) :-
    X @< Y.
key_equal((>), X=_, Y=_) :-
    X @> Y.

/**
 * open_descriptor_queries(Descriptors, Read_Descriptors, Write_Descriptors, Query_Objects) is det.
 *
 * open descriptors responsibly
 */
open_descriptor_queries(Descriptors, Read_Descriptors, Write_Descriptors, Query_Objects) :-
    open_descriptor_queries_uniquely(Descriptors, Read_Descriptors, Write_Descriptors, [], Map),
    presort(key_equal,Map,Sorted_Map),
    maplist([_Descriptor=Query_Object,Query_Object]>>true, Sorted_Map, Query_Objects).

/**
 * with_transaction(+Pre_Descriptors, +Read_Descriptors, +Write_Descriptors, :Query_Update, :Post, -Witnesses) is semidet.
 */
:- meta_predicate with_transaction(+,+,+,+,+,:,:,-).
with_transaction(Pre_Descriptors,
                 Read_Descriptors,
                 Write_Descriptors,
                 Update_Query_Objects,
                 Post_Query_Objects,
                 Query_Update,
                 Post,
                 _Witnesses) :-
    % turn descriptors into query objects
    between(1,5,_),
    % Get unique query objects per descriptor
    open_descriptor_queries(Pre_Descriptors, Read_Descriptors, Write_Desriptors, Update_Query_Objects),
    % call update_query which will use those query objects
    call_or_die(Query_Update, 'unable to perform the query'),

    % turn builders into layers resulting in post query objects
    maplist(commit_query_object,
            Update_Query_Objects,
            Post_Query_Objects),

    % call post with post query objects for final check
    call_or_die(Post, 'post condition failed'),

    % set heads (magic!)
    set_heads(Post_Query_Objects),
    !.
with_transaction(Pre_Descriptors,
                 Read_Descriptors,
                 Write_Descriptors,
                 Update_Query_Objects,
                 Post_Query_Objects,
                 Query_Update,
                 Post,
                 Witnesses) :-
    die('too many transaction retries, dying.').

descriptor_compare('=', Left, Right) :-
    Left.descriptor = Right.descriptor,
    !.
descriptor_compare('<', Left, Right) :-
    Left @< Right,
    !.
descriptor_compare('>', _Left, _Right).

collect_query_objects(Query_Objects,
                      Ref_Query_Objects,
                      Repo_Query_Objects,
                      Label_Query_Objects) :-
    include([Query_Object]>>(ref_descriptor{} :< Query_Object.collection_descriptor),
            Query_Objects,
            Ref_Query_Objects),

    include([Query_Object]>>(repository_descriptor{} :< Query_Object.collection_descriptor),
            Query_Objects,
            Toplevel_Repo_Query_Objects),

    maplist([Ref_Query_Object,Repo_Query_Object]>>(
                Ref_Query_Object.parent = Repo_Query_Object),
            Ref_Query_Objects,
            Second_Level_Repo_Query_Objects),

    union(Toplevel_Repo_Query_Objects,
          Second_Level_Repo_Query_Objects,
          Repo_Query_Objects),

    include([Query_Object]>>(database_descriptor{} :< Query_Object.collection_descriptor),
            Query_Objects,
            Toplevel_Label_Query_Objects),

    maplist([Repo_Query_Object,Label_Query_Object]>>(
                Repo_Query_Object.parent = Label_Query_Object),
            Repo_Query_Objects,
            Second_Level_Label_Query_Objects),

    union(Toplevel_Label_Query_Objects,
          Second_Level_Label_Query_Objects,
          Label_Query_Objects).

set_ref_head(Ref_Query_Object, New_Ref_Query_Object) :-
    Ref_Name = Ref_Query_Object.descriptor.ref_name,
    Last_Commit = Ref_Query_Object.descriptor.last_commit,
    Ref_Query_Object.instance_read_objects = [Ref_Layer],
    open_write(Ref_Layer, Ref_Layer_Builder),

    Ref_Instance_Read_Objects = Ref_Query_Object.instance_read_objects,
    maplist([Ref_Instance_Read_Object]>>(Ref_Instance_Read_Object.read),
            Ref_Instance_Read_Objects, Instance_Layers),
    Ref_Schema_Read_Objects = Ref_Query_Object.schema_read_objects,
    maplist([Ref_Schema_Read_Object]>>(Ref_Schema_Read_Object.read),
            Ref_Schema_Read_Objects, Schema_Layers),
    Ref_Inference_Read_Objects = Ref_Query_Object.inference_read_objects,
    maplist([Ref_Inference_Read_Object]>>(Ref_Inference_Read_Object.read),
            Ref_Inference_Read_Objects, Inference_Layers),


    atomic_list_concat([Ref_Name,'/document/'],Ref_Base),
    random_uri(Ref_Base,'Commit',Commit_URI),
    write_ref_commit(Ref_Layer_Builder, Last_Commit, Commit_URI),

    maplist({Commit_URI,Ref_Layer,Ref_Base,Ref_Layer_Builder}/[Layer]>>
            write_layer_to_commit(instance,Ref_Layer,Ref_Layer_Builder,Ref_Base,Layer,Commit_URI),
            Instance_Layers),

    maplist({Commit_URI,Ref_Layer,Ref_Base,Ref_Layer_Builder}/[Layer]>>
            write_layer_to_commit(schema,Ref_Layer,Ref_Layer_Builder,Ref_Base,Layer,Commit_URI),
            Schema_Layers),

    maplist({Commit_URI,Ref_Layer,Ref_Base,Ref_Layer_Builder}/[Layer_ID]>>
            write_layer_to_commit(inference,Ref_Layer,Ref_Layer_Builder,Ref_Base,Layer,Commit_URI),
            Inference_Layers),

    nb_commit(Ref_Layer_Builder, New_Ref_Layer),
    New_Ref_Query_Object = Ref_Query_Object.put(_{instance_read_object: [New_Ref_Layer]}).

:- table metadata_prefix_expand/2
metadata_prefix_expand(Prefixed_URI,URI) :-
    global_prefix_expand(Prefixed_URI, CommitType).

write_ref_commit(Ref_Layer_Builder,Ref_URI,Author,Last_Commit_URI,Commit_URI) :-
    metadata_prefix_expand(terminus:'Commit', Commit_Type),
    metadata_prefix_expand(rdf:type, RDF_Type),
    metadata_prefix_expand(xsd:string, XSD_String),
    metadata_prefix_expand(terminus:ref_commit, Ref_Commit_Prop),
    metadata_prefix_expand(terminus:commit_parent, Parent_Prop),
    metadata_prefix_expand(terminus:commit_timestamp, Commit_Timestamp_Prop),
    metadata_prefix_expand(terminus:commit_author, Author_Prop),
    metadata_prefix_expand(terminus:'Branch', Branch_Type),
    metadata_prefix_expand(terminus:no_commit, No_Commit_URI),
    unix_time_string_now(Unix_Time_String),
    object_storage(literal(Unix_Time_String,XSD_String), Timestamp_Literal),
    object_storage(literal(Author,XSD_String), Author_Literal),
    nb_add_triple(Write_Builder, Commit_URI, RDF_Type, node(Commit_Type)),
    (   Last_Commit_URI = No_Commit_URI
    ->  true
    ;   nb_remove_triple(Write_Builder, Ref_URI, Ref_Commit_Prop, node(Last_Commit_URI)),
        nb_add_triple(Write_Builder, Commit_URI, Parent_Prop, node(Last_Commit_URI))),
    nb_add_triple(Write_Builder, Ref_URI, Ref_Commit_Prop, node(Commit_URI)),
    nb_add_triple(Write_Builder, Commit_URI, RDF_Type, node(Commit_Type)),
    nb_add_triple(Write_Builder, Commit_URI, Commit_Timestamp_Prop, value(Timestamp_Literal)),
    nb_add_triple(Write_Builder, Commit_URI, Author_Prop, value(Author_Literal)).

write_layer_to_commit(Type,Ref_Layer,Ref_Layer_Builder,Ref_Base,Layer,Commit_URI) :-
    metadata_prefix_expand(terminus:Type, Graph_Property),
    metadata_prefix_expand(terminus:'Layer', Layer_Type),
    metadata_prefix_expand(terminus:layer_id, Layer_ID_Prop),
    metadata_prefix_expand(terminus:layer_parent, Layer_Parent_Prop),
    metadata_prefix_expand(rdf:type, RDF_Type),
    metadata_prefix_expand(xsd:string, XSD_String),
    metadata_prefix_expand(xsd:integer, XSD_Integer),
    layer_to_id(Layer,Layer_ID),
    object_storage(literal(Layer_ID,XSD_String), Layer_Literal),
    atomic_list_concat([Ref_Base,'/document/Layer'],Layer_Base),
    parent(Layer,Parent),
    layer_to_id(Parent,Parent_Layer_ID),
    idgen(Layer_Base ,[Layer_ID], Layer_URI),
    idgen(Layer_Base ,[Parent_Layer_ID], Parent_Layer_URI),
    nb_add_triple(Write_Builder, Layer_URI, RDF_Type, node(Layer_Type)),
    nb_add_triple(Write_Builder, Commit_URI, Graph_Property, node(Layer_URI)),
    nb_add_triple(Write_Builder, Layer_URI, Layer_ID_Prop, value(Layer_Literal)),
    nb_add_triple(Write_Builder, Layer_URI, Layer_Parent_Prop, node(Parent_Layer_ID)).

unix_time_string_now(Unix_Time_String) :-
    get_time(Time),
    Unix_Time is floor(Time),
    number_string(Unix_Time,Unix_Time_String).

random_uri(Base,Type,URI) :-
    atomic_list_concat([Base,Type],Type_Base),
    Size is 2 ** (20 * 8),
    random(0, Size, Num),
    format(atom(Random), '~36r', [Num]),
    idgen(Type_Base ,[Random], URI).

nb_remove_shadow_layer(Layer_Builder, Repo_Name, Layer_Id) :-
    metadata_prefix_expand(terminus:'ShadowLayer', Layer_Type),
    metadata_prefix_expand(terminus:layer_id, Layer_ID_Prop),
    metadata_prefix_expand(rdf:type, RDF_Type),
    metadata_prefix_expand(xsd:string, XSD_String),

    atomic_list_concat([Repo_Name,'/document/ShadowLayer'], Layer_Base),

    idgen(Layer_Base, [Layer_Id], Layer_URI),
    object_storage(literal(Layer_Id,XSD_String), Layer_Literal),

    ignore(nb_remove_triple(Layer_Builder, Layer_URI, RDF_Type, node(Layer_Type))),
    ignore(nb_remove_triple(Layer_Builder, Layer_URI, Layer_ID_Prop, value(Layer_Literal))).

nb_add_shadow_layer(Layer_Builder, Repo_Name, Layer_Id) :-
    metadata_prefix_expand(terminus:'ShadowLayer', Layer_Type),
    metadata_prefix_expand(terminus:layer_id, Layer_ID_Prop),
    metadata_prefix_expand(rdf:type, RDF_Type),
    metadata_prefix_expand(xsd:string, XSD_String),

    atomic_list_concat([Repo_Name,'/document/ShadowLayer'], Layer_Base),

    idgen(Layer_Base, [Layer_Id], Layer_URI),
    object_storage(literal(Layer_Id,XSD_String), Layer_Literal),

    nb_add_triple(Layer_Builder, Layer_URI, RDF_Type, node(Layer_Type)),
    nb_add_triple(Layer_Builder, Layer_URI, Layer_ID_Prop, value(Layer_Literal)).


update_repository_data(Repo_Name, Repo_Layer_Builder, URI, Layer) :-
    layer_to_id(Layer, Layer_Id),
    parent(Layer, Parent),
    layer_to_id(Parent, Parent_Id),

    metadata_prefix_expand(terminus:repository_head, Repository_Head_Property),
    atomic_list_concat([Repo_Name,'/document/ShadowLayer'], Layer_Base),

    idgen(Layer_Base, [Layer_Id], Layer_URI),
    idgen(Layer_Base, [Parent_Id], Parent_URI),

    nb_remove_shadow_layer(Repo_Layer_Builder, Parent_URI),
    nb_add_shadow_layer(Repo_Layer_Builder, Layer_Id),

    nb_remove_triple(URI, Repository_Head_Property, node(Parent_URI)),
    nb_add_triple(URI, Repository_Head_Property, node(Layer_URI)).


set_repo_head(Repo_Query_Object - Ref_Query_Objects, New_Repo_Query_Object) :-
    open_write(Repo_Query_Object.repository_layer, Repo_Layer_Builder),
    Repo_Name = Repo_Query_Object.descriptor.repo_name,
    maplist({Repo_Name, Repo_Layer_Builder}/[Ref_Query_Object]>>([Layer] = Ref_Query_Object.instance_read_objects,
                                                                 URI = Ref_Query_Object.descriptor.ref_name,
                                                                 update_repository_data(Repo_Name, Repo_Layer_Builder, URI, Layer)),
            Ref_Query_Objects),

    nb_commit(Repo_Layer_Builder, Repo_Layer),
    New_Repo_Query_Object = Repo_Query_Object.put(_{instance_read_object: [New_Repo_Layer]}).

query_object_parents(Query_Objects,Query_Object_Candidates, Child_Parent_Pairs) :-
    findall(Query_Object - Associated_Parents,
            (   member(Query_Object,Query_Objects),
                convlist({Query_Object}/[Candidate_Query_Object]>>
                         descriptor_compare((=),Query_Object.parent.descriptor,
                                                Candidate_Query_Object.descriptor),
                         Query_Objects, Associated_Parents))
            Child_Parent_Pairs).

set_heads(Query_Objects) :-
    % split query objects by type (ref, repo, label)
    collect_query_objects(Query_Objects,
                          Ref_Query_Objects,
                          Repo_Query_Objects,
                          Label_Query_Objects),

    % set heads for all the refs
    maplist(set_ref_head, Ref_Query_Objects, New_Ref_Query_Objects),

    query_object_parents(Repo_Query_Objects, New_Ref_Query_Objects, Repo_Refs),
    maplist(set_repo_head, Repo_Refs, New_Repo_Query_Objects),

    query_object_parents(Label_Query_Objects, New_Repo_Query_Objects, Label_Repos),
    maplist(set_label_head, Label_Repos).
