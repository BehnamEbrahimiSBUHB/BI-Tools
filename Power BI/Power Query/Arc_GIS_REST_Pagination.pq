(
    // Function Parameters
    serviceUrl as text,           // Example: "https://host/arcgis/rest/services/ServiceName/FeatureServer" or "/MapServer"
    layerId as number,            // Example: 0
    optional whereClause as text, // Optional: Filter clause, e.g., "STATUS = 'Active'". Defaults to fetching all records.
    optional outFields as text,   // Optional: Comma-separated list of fields, e.g., "ObjectID,Field1". Defaults to "*".
    optional recordsPerRequest as number // Optional: Override detected/default max record count. Use with caution.
) as table =>
let
    // --- Documentation ---
    Documentation = [
        Documentation.Name = "fx_GetArcGISLayerData_Paginated",
        Documentation.Description = "Connects to an ArcGIS REST API Layer (FeatureServer or MapServer) and retrieves ALL feature attributes as a table, automatically handling pagination.",
        Documentation.LongDescription = "Queries the layer metadata to determine the max record count per request. Uses List.Generate to iteratively fetch batches of records using resultOffset until all records matching the whereClause are retrieved. Combines batches and expands attributes. Includes error handling for metadata and data requests. Remember to configure authentication separately in Power BI's data source settings.",
        Documentation.Category = "Data Access",
        Documentation.Source = "ArcGIS REST API",
        Documentation.Version = "2.0 (Pagination Added)",
        Documentation.Author = "AI Assistant (Modified by User)",
        Documentation.Examples = {[
            Description = "Get all fields and ALL records from Layer 0 of a specific FeatureServer.",
            Code = "fx_GetArcGISLayerData_Paginated(""https://services1.arcgis.com/ESMARspQHYMw9BZ9/ArcGIS/rest/services/LSOA_2011_to_LSOA_2021_to_Local_Authority_District_2022_Lookup_for_England__2022/FeatureServer"", 0)",
            Result = "Table containing attributes from ALL features."
        ],[
            Description = "Get specific fields for ALL features where POPULATION > 10000 from Layer 5 of a MapServer.",
            Code = "fx_GetArcGISLayerData_Paginated(""https://sampleserver6.arcgisonline.com/arcgis/rest/services/USA/MapServer"", 5, ""POPULATION > 10000"", ""ObjectID,STATE_NAME,POPULATION"")",
            Result = "Table containing ObjectID, STATE_NAME, POPULATION for ALL matching features."
        ]}
    ],

    // --- Function Logic ---

    // Set defaults for optional parameters
    ActualWhereClause = if whereClause = null or Text.Trim(whereClause) = "" then "1=1" else whereClause,
    ActualOutFields = if outFields = null or Text.Trim(outFields) = "" then "*" else outFields,
    BaseLayerUrl = serviceUrl & "/" & Text.From(layerId),

    // --- Step 1: Get Max Record Count from Layer Metadata ---
    MetadataUrl = BaseLayerUrl & "?f=json",
    DefaultMaxRecords = 1000, // Default if metadata lookup fails
    MaxRecordsToRequest = try
                            if recordsPerRequest <> null then recordsPerRequest
                            else let
                                Source = Json.Document(Web.Contents(MetadataUrl, [Timeout=#duration(0, 0, 1, 0)])), // 1 min timeout for metadata
                                // ArcGIS Online Feature Services store it here:
                                OnlineMax = Source[advancedQueryCapabilities][maxRecordCount],
                                // Older ArcGIS Server versions might store it directly:
                                ServerMax = Source[maxRecordCount],
                                Result = if OnlineMax <> null then OnlineMax else if ServerMax <> null then ServerMax else DefaultMaxRecords
                            in Result
                          otherwise DefaultMaxRecords,

    // --- Step 2: Define Function to Fetch a Single Batch ---
    // This function takes the starting offset and returns the parsed JSON *record* (including features and exceededTransferLimit flag)
    FetchBatch = (offset as number) as record =>
        let
            QueryParameters = [
                where = ActualWhereClause,
                outFields = ActualOutFields,
                resultOffset = Text.From(offset),
                resultRecordCount = Text.From(MaxRecordsToRequest), // Tell server how many we want (up to its limit)
                returnGeometry = "false", // Usually don't need geometry for BI tables
                f = "json",
                // Some servers might need this for pagination:
                orderByFields = if ActualOutFields = "*" or not Text.Contains(ActualOutFields, "OBJECTID", Comparer.OrdinalIgnoreCase) then null else "OBJECTID" // Order by OBJECTID if available & requested, helps ensure consistent paging
                // standardizedQueries = "false" // uncomment for very old servers if pagination fails
            ],
            // Remove null parameters before building query string
            CleanedQueryParameters = Record.SelectFields(QueryParameters, List.Select(Record.FieldNames(QueryParameters), each Record.Field(QueryParameters, _) <> null)),
            FullQueryUrl = BaseLayerUrl & "/query?" & Uri.BuildQueryString(CleanedQueryParameters),
            // Fetch data with basic error handling for this batch
            SourceJson = try Json.Document(Web.Contents(FullQueryUrl, [Timeout=#duration(0, 0, 10, 0), IsRetry=true])) otherwise null // 10 min timeout, allow retry
        in
            SourceJson,

    // --- Step 3: Generate List of Batches using List.Generate ---
    GeneratedBatches = List.Generate(
        () => [Offset = 0, Result = FetchBatch(0)],                                  // Initial state: Fetch first batch (offset 0)
        each [Result] <> null                                                        // Continue condition: Keep going as long as the last fetch didn't fail
             and Record.HasFields([Result], "features")                              // and the result has a 'features' field
             and not List.IsEmpty([Result][features]),                               // and the features list is not empty (stops if a page is unexpectedly empty)
             // Optional stricter check: and [Offset] < MaxTotalRecords if you fetch total count first
        each let                                                                     // Next state function:
                CurrentResult = [Result],
                NextOffset = [Offset] + MaxRecordsToRequest,                         // Calculate next offset based on MaxRecords requested
                HasMoreData = Record.HasFields(CurrentResult,"exceededTransferLimit") // Check if flag exists
                              and CurrentResult[exceededTransferLimit]? = true       // Check if flag is true (using ? handles null safely)
             in
                if HasMoreData then [Offset = NextOffset, Result = FetchBatch(NextOffset)] // If more data expected, fetch next batch
                else [Offset = NextOffset, Result = null],                           // Otherwise, set Result to null to stop generation
        each [Result][features]                                                      // Result selector: Extract the 'features' list from the valid Result record
    ),

    // --- Step 4: Combine Batches and Convert to Table ---
    AllFeaturesList = List.Combine(List.Select(GeneratedBatches, each _ <> null)), // Combine all non-null feature lists

    // --- Step 5: Process Combined List into Final Table ---
    ResultTable = if List.IsEmpty(AllFeaturesList) then
         // Return empty table with a message if no features found at all
         #table({"Status"}, {{"No features found matching the criteria or layer is empty."}})
    else
        let
             // Convert the final list of feature records to a table
            featuresTable = Table.FromList(AllFeaturesList, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
             // Check if the 'Column1' contains records (it should) and has 'attributes'
            FirstRecord = featuresTable{0}[Column1],
            AttributesRecord = if Record.HasFields(FirstRecord, "attributes") then FirstRecord[attributes] else null,

            FinalTable = if AttributesRecord = null then
                             #table({"Error"}, {{"Failed to find 'attributes' in the first feature record."}})
                         else
                             let
                                // Get field names from the attributes of the first record
                                AttributeFieldNames = Record.FieldNames(AttributesRecord),
                                // Expand the 'attributes' record column
                                ExpandedAttributes = Table.ExpandRecordColumn(featuresTable, "Column1", {"attributes"}, {"attributes"}),
                                ExpandedData = Table.ExpandRecordColumn(ExpandedAttributes, "attributes", AttributeFieldNames, AttributeFieldNames)
                             in
                                ExpandedData
        in
            FinalTable
in
    ResultTable
