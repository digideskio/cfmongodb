<cfcomponent accessors="true">

	<cfproperty name="mongoConfig">
	<cfproperty name="mongoFactory">
	<cfproperty name="mongoUtil">

<cfscript>

	/**
	* You can init CFMongoDB in two ways:
	   1) drop the included jars into your CF's lib path (restart CF)
	   2) use Mark Mandel's javaloader (included). You needn't restart CF)

	   --1: putting the jars into CF's lib path
		mongoConfig = createObject('component','cfmongodb.core.MongoConfig').init(dbName="mongorocks");
		mongo = createObject('component','cfmongodb.core.Mongo').init(mongoConfig);

	   --2: using javaloader
		javaloaderFactory = createObject('component','cfmongodb.core.JavaloaderFactory').init();
		mongoConfig = createObject('component','cfmongodb.core.MongoConfig').init(dbName="mongorocks", mongoFactory=javaloaderFactory);
		mongo = createObject('component','cfmongodb.core.Mongo').init(mongoConfig);

	  Note that authentication credentials, if set in MongoConfig, will be used to authenticate against the database.
	*
	*/
	function init(MongoConfig="#createObject('MongoConfig')#"){
		setMongoConfig(arguments.MongoConfig);
		setMongoFactory(mongoConfig.getMongoFactory());
		variables.mongo = mongofactory.getObject("com.mongodb.Mongo");

		if( arrayLen( mongoConfig.getServers() ) GT 1 ){
			variables.mongo.init(variables.mongoConfig.getServers());
		} else {
			var _server = mongoConfig.getServers()[1];
			writeDump(_server);
			writeoutput(_server.getHost()); writeOutput(_server.getPort());
			variables.mongo.init( _server.getHost(), _server.getPort() );
		}

		mongoUtil = new MongoUtil(mongoFactory);

		// Check for authentication, and if we have details set call it once on this database instance
		if ( isAuthenticationRequired() ) {
			var authResult = authenticate(mongoConfig.getAuthDetails().username, mongoConfig.getAuthDetails().password);
			if(not authResult.authenticated and structIsEmpty(authResult.error) ) {
				throw( message="Error authenticating against MongoDB Database", type="AuthenticationFailedException" );
			} else if( not authResult.authenticated ) {
				throw(object=authResult.error);
			}
		}

		return this;
	}

	/**
	* Authenticates connection/db with given name and password

		Typical usage:
		mongoConfig.init(...);
		mongoConfig.setAuthDetails( username, password );
		mongo = new Mongo(mongoConfig);

		If you set credentials to mongoConfig, Mongo.cfc will use those credentials to authenticate upon initialization.
		If authentication fails, an error will be thrown
	*
	*/
	struct function authenticate( string username, string password ){
		var result = {authenticated = false, error={}};
		try{
			result.authenticated = getMongoDB( variables.mongoConfig ).authenticate( arguments.username, arguments.password.toCharArray() );
		}
		catch( any e ){
			result.error = e;
		}
		return result;
	}

	/**
	* Attempts to determine whether mongod is running in auth mode
	*/
	boolean function isAuthenticationRequired(){
		try{
			getIndexes("foo");
			return false;
		}catch(any e){
			return true;
		}
	}

	/**
	*  Adds a user to the database
	*/
	function addUser( string username, string password) {
		getMongoDB( variables.mongoConfig ).addUser(arguments.username, arguments.password.toCharArray());
		return this;
	}

	/**
	* Drops the database currently specified in MongoConfig
	*/
	function dropDatabase() {
		variables.mongo.dropDatabase(variables.mongoConfig.getDBName());
		return this;
	}


	/**
	* Closes the underlying mongodb object. Once closed, you cannot perform additional mongo operations and you'll need to init a new mongo.
	  Best practice is to close mongo in your Application.cfc's onApplicationStop() method. Something like:
	  getBeanFactory().getBean("mongo").close();
	  or
	  application.mongo.close()

	  depending on how you're initializing and making mongo available to your app

	  NOTE: If you do not close your mongo object, you WILL leak connections!
	*/
	function close(){
		try{
			variables.mongo.close();
		}catch(any e){
			//the error that this throws *appears* to be harmless.
			writeLog("Error closing Mongo: " & e.message);
		}
		return this;
	}

	/**
	* Returns the last error for the current connection.
	*/
	function getLastError()
	{
		return getMongoDB().getLastError();
	}

	/**
	* For simple mongo _id searches, use findById(), like so:

	  byID = mongo.findById( url.personId, collection );
	*/
	function findById( id, string collectionName, mongoConfig="" ){
		var collection = getMongoDBCollection(collectionName, mongoConfig);
		var result = collection.findOne( mongoUtil.newIDCriteriaObject(id) );
		return mongoUtil.toCF( result );
	}

	/**
	* Run a query against MongoDB.
	  Query returns a SearchBuilder object, which you'll call functions on.
	  Finally, you'll use various "execution" functions on the SearchBuilder to get a SearchResult object,
	  which provides useful functions for working with your results.

	  kidSearch = mongo.query( collection ).between("KIDS.AGE", 2, 30).search();
	  writeDump( kidSearch.asArray() );

	  See gettingstarted.cfm for many examples
	*/
	function query(string collectionName, mongoConfig=""){
	   var db = getMongoDB(mongoConfig);
	   return new SearchBuilder(collectionName,db,mongoUtil);
	}

	/**
	* Runs mongodb's distinct() command. Returns an array of distinct values
	*
	  distinctAges = mongo.distinct( "KIDS.AGE", "people" );
	*/
	function distinct(string key, string collectionName, mongoConfig=""){
		return getMongoDBCollection(collectionName, mongoConfig).distinct( key );
	}

	/**
	* So important we need to provide top level access to it and make it as easy to use as possible.

	FindAndModify is critical for queue-like operations. Its atomicity removes the traditional need to synchronize higher-level methods to ensure queue elements only get processed once.

	http://www.mongodb.org/display/DOCS/findandmodify+Command

	This function assumes you are using this to *apply* additional changes to the "found" document. If you wish to overwrite, pass overwriteExisting=true. One bristles at the thought

	*/
	function findAndModify(struct query, struct fields, any sort, boolean remove=false, struct update, boolean returnNew=true, boolean upsert=false, boolean applySet=true, string collectionName, mongoConfig=""){
		// Confirm our complex defaults exist; need this chunk of muck because CFBuilder 1 breaks with complex datatypes in defaults
		local.argumentDefaults = {sort={"_id"=1},fields={}};
		for(local.k in local.argumentDefaults)
		{
			if (!structKeyExists(arguments, local.k))
			{
				arguments[local.k] = local.argumentDefaults[local.k];
			}
		}

		var collection = getMongoDBCollection(collectionName, mongoConfig);
		//must apply $set, otherwise old struct is overwritten
		if( applySet ){
			update = { "$set" = mongoUtil.toMongo(update)  };
		}
		if( not isStruct( sort ) ){
			sort = mongoUtil.createOrderedDBObject(sort);
		} else {
			sort = mongoUtil.toMongo( sort );
		}

		var updated = collection.findAndModify(
			mongoUtil.toMongo(query),
			mongoUtil.toMongo(fields),
			sort,
			remove,
			mongoUtil.toMongo(update),
			returnNew,
			upsert
		);
		if( isNull(updated) ) return {};

		return mongoUtil.toCF(updated);
	}

	/**
	* Executes Mongo's group() command. Returns an array of structs.

	  usage, including optional 'query':

	  result = mongo.group( "tasks", "STATUS,OWNER", {TOTAL=0}, "function(obj,agg){ agg.TOTAL++; }, {SOMENUM = {"$gt" = 5}}" );

	  See examples/aggregation/group.cfm for detail
	*/
	function group( collectionName, keys, initial, reduce, query, keyf="", finalize="" ){

		if (!structKeyExists(arguments, 'query'))
		{
			arguments.query = {};
		}


		var collection = getMongoDBCollection(collectionName);
		var dbCommand =
			{ "group" =
				{"ns" = collectionName,
				"key" = mongoUtil.createOrderedDBObject(keys),
				"cond" = query,
				"initial" = initial,
				"$reduce" = trim(reduce),
				"finalize" = trim(finalize)
				}
			};
		if( len(trim(keyf)) ){
			structDelete(dbCommand.group,"key");
			dbCommand.group["$keyf"] = trim(keyf);
		}
		var result = getMongoDB().command( mongoUtil.toMongo(dbCommand) );
		return result["retval"];
	}

	/**
	* Executes Mongo's mapReduce command. Returns a MapReduceResult object

	  basic usage:

	  result = mongo.mapReduce( collectionName="tasks", map=map, reduce=reduce );


	  See examples/aggregation/mapReduce for detail
	*/
	function mapReduce( collectionName, map, reduce, query, sort, limit="0", out="", keeptemp="false", finalize="", scope, verbose="true", outType="normal"  ){

		// Confirm our complex defaults exist; need this hunk of muck because CFBuilder 1 breaks with complex datatypes as defaults
		local.argumentDefaults = {
			 query={}
			,sort={}
			,scope={}
		};
		for(local.k in local.argumentDefaults)
		{
			if (!structKeyExists(arguments, local.k))
			{
				arguments[local.k] = local.argumentDefaults[local.k];
			}
		}

		var dbCommand = mongoUtil.createOrderedDBObject(
			[
				{"mapreduce"=collectionName}, {"map"=trim(map)}, {"reduce"=trim(reduce)}
				, {"query"=query}, {"sort"=sort}, {"limit"=limit}, {"keeptemp"=keeptemp}, {"finalize"=trim(finalize)}, {"scope"=scope}, {"verbose"=verbose}, {"outType"=outType}
			] );
		if( trim(arguments.out) neq "" ){
			dbCommand.append( "out", arguments.out );
		}
		var commandResult = getMongoDB().command( dbCommand );
		var searchResult = this.query( commandResult["result"] ).search();
		var mapReduceResult = createObject("component", "MapReduceResult").init(dbCommand, commandResult, searchResult, mongoUtil);
		return mapReduceResult;
	}

	/**
	*  Saves a struct into the collection; Returns the newly-saved Document's _id; populates the struct with that _id

		person = {name="bill", badmofo=true};
		mongo.save( person, "coolpeople" );
	*/
	function save(struct doc, string collectionName, mongoConfig=""){
	   var collection = getMongoDBCollection(collectionName, mongoConfig);
	   if( structKeyExists(doc, "_id") ){
	       update( doc = doc, collectionName = collectionName, mongoConfig = mongoConfig);
	   } else {
		   var dbObject =  mongoUtil.toMongo(doc);
		   collection.insert([dbObject]);
		   doc["_id"] =  dbObject.get("_id");
	   }
	   return doc["_id"];
	}

	/**
	* Saves an array of structs into the collection. Can also save an array of pre-created CFBasicDBObjects

		people = [{name="bill", badmofo=true}, {name="marc", badmofo=true}];
		mongo.saveAll( people, "coolpeople" );
	*/
	function saveAll(array docs, string collectionName, mongoConfig=""){
		if( arrayIsEmpty(docs) ) return docs;

		var collection = getMongoDBCollection(collectionName, mongoConfig);
		var i = 1;
		if( getMetadata(docs[1]).getCanonicalName() eq "com.mongodb.CFBasicDBObject" ){
			collection.insert(docs);
		} else {
			var total = arrayLen(docs);
			var allDocs = [];
			for(i=1; i LTE total; i++){
				arrayAppend( allDocs, mongoUtil.toMongo(docs[i]) );
			}
			collection.insert(allDocs);
		}
		return docs;
	}

	/**
	* Updates a document in the collection.

	The "doc" argument will either be an existing Mongo document to be updated based on its _id, or it will be a document that will be "applied" to any documents that match the "query" argument

	To update a single existing document, simply pass that document and update() will update the document by its _id:
	 person = person.findById(url.id);
	 person.something = "something else";
	 mongo.update( person, "people" );

	To update a document by a criteria query and have the "doc" argument applied to a single found instance:
	update = {STATUS = "running"};
	query = {STATUS = "pending"};
	mongo.update( update, "tasks", query );

	To update multiple documents by a criteria query and have the "doc" argument applied to all matching instances, pass multi=true
	mongo.update( update, "tasks", query, false, true )

	Pass upsert=true to create a document if no documents are found that match the query criteria
	*/
	function update(doc, collectionName, query, upsert=false, multi=false, applySet=true, mongoConfig=""){

		if (!structKeyExists(arguments, 'query'))
		{
			arguments.query = {};
		}

	   var collection = getMongoDBCollection(collectionName, mongoConfig);

	   if( structIsEmpty(query) ){
		  query = mongoUtil.newIDCriteriaObject(doc['_id'].toString());
		  var dbo = mongoUtil.toMongo(doc);
	   } else{
	   	  query = mongoUtil.toMongo(query);
		  var keys = structkeyList(doc);
		  if( applySet ){
		  	doc = { "$set" = mongoUtil.toMongo(doc)  };
		  }

	   }
	   var dbo = mongoUtil.toMongo(doc);
	   collection.update( query, dbo, upsert, multi );
	}

	/**
	* Remove one or more documents from the collection.

	  If the document has an "_id", this will remove that single document by its _id.

	  Otherwise, "doc" is treated as a "criteria" object. For example, if doc is {STATUS="complete"}, then all documents matching that criteria would be removed.

	  pass an empty struct to remove everything from the collection: mongo.remove({}, collection);
	*/
	function remove(doc, collectionName, mongoConfig=""){
	   var collection = getMongoDBCollection(collectionName, mongoConfig);
	   if( structKeyExists(doc, "_id") ){
	   	return removeById( doc["_id"], collectionName, mongoConfig );
	   }
	   var dbo = mongoUtil.toMongo(doc);
	   var writeResult = collection.remove( dbo );
	   return writeResult;
	}

	/**
	* Convenience for removing a document from the collection by the String representation of its ObjectId

		mongo.removeById(url.id, somecollection);
	*/
	function removeById( id, collectionName, mongoConfig="" ){
		var collection = getMongoDBCollection(collectionName, mongoConfig);
		return collection.remove( mongoUtil.newIDCriteriaObject(id) );
	}


	/**
	* The array of fields can either be
	a) an array of field names. The sort direction will be "1"
	b) an array of structs in the form of fieldname=direction. Eg:

	[
		{lastname=1},
		{dob=-1}
	]

	*/
	public array function ensureIndex(array fields, collectionName, unique=false, mongoConfig=""){
	 	var collection = getMongoDBCollection(collectionName, mongoConfig);
	 	var pos = 1;
	 	var doc = {};
		var indexName = "";
		var fieldName = "";

	 	for( pos = 1; pos LTE arrayLen(fields); pos++ ){
			if( isSimpleValue(fields[pos]) ){
				fieldName = fields[pos];
				doc[ fieldName ] = 1;
			} else {
				fieldName = structKeyList(fields[pos]);
				doc[ fieldName ] = fields[pos][fieldName];
			}
			indexName = listAppend( indexName, fieldName, "_");
	 	}

	 	var dbo = mongoUtil.toMongo( doc );
	 	collection.ensureIndex( dbo, "_#indexName#_", unique );

	 	return getIndexes(collectionName, mongoConfig);
	}

	/**
	* Ensures a "2d" index on a single field. If another 2d index exists on the same collection, this will error
	*/
	public array function ensureGeoIndex(field, collectionName, min="", max="", mongoConfig=""){
		var collection = getMongoDBCollection(collectionName, mongoConfig);
		var doc = { "#arguments.field#" = "2d" };
		var options = {};
		if( isNumeric(arguments.min) and isNumeric(arguments.max) ){
			options = {"min" = arguments.min, "max" = arguments.max};
		}
		//need to do this bit of getObject ugliness b/c the CFBasicDBObject will convert "2d" to a double. whoops.
		collection.ensureIndex( mongoUtil.getMongoFactory().getObject("com.mongodb.BasicDBObject").init(doc), mongoUtil.toMongo(options) );
		return getIndexes( collectionName, mongoConfig );
	}


	/**
	* Returns an array with information about all of the indexes for the collection
	*/
	public array function getIndexes(collectionName, mongoConfig=""){
		var collection = getMongoDBCollection(collectionName, mongoConfig);
		var indexes = collection.getIndexInfo().toArray();
		return indexes;
	}

	/**
	* Drops all indexes from the collection
	*/
	public array function dropIndexes(collectionName, mongoConfig=""){
		getMongoDBCollection( collectionName, mongoConfig ).dropIndexes();
		return getIndexes( collectionName, mongoConfig );
	}

	/**
	* Decide whether to use the MongoConfig in the variables scope, the one being passed around as arguments, or create a new one
	*/
	function getMongoConfig(mongoConfig=""){
		if(isSimpleValue(arguments.mongoConfig)){
			mongoConfig = variables.mongoConfig;
		}
		return mongoConfig;
	}

	/**
	 * Get the underlying Java driver's Mongo object
	 */
	function getMongo(mongoConfig=""){
		return variables.mongo;
	}

	/**
	 * Get the underlying Java driver's DB object
	 */
	function getMongoDB(mongoConfig=""){
		var jMongo = getMongo(mongoConfig);
		return jMongo.getDb(getMongoConfig(mongoConfig).getDefaults().dbName);
	}

	/**
	* Get the underlying Java driver's DBCollection object for the given collection
	*/
	function getMongoDBCollection(collectionName="", mongoConfig=""){
		var jMongoDB = getMongoDB(mongoConfig);
		return jMongoDB.getCollection(collectionName);
	}

</cfscript>

</cfcomponent>
