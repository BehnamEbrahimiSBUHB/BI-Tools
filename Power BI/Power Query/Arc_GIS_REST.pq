(
    // Function Parameters
    serviceUrl as text,    // Example: "https://services1.arcgis.com/ESMARspQHYMw9BZ9/ArcGIS/rest/services/Your_Service_Name/FeatureServer"
                           //          OR "https://yourserver/arcgis/rest/services/Your_Folder/Your_Service_Name/MapServer"
    layerId as number,     // Example: 0
    optional whereClause as text, // Optional: Filter clause, e.g., "STATUS = 'Active'". Defaults to fetching all records (within server limits).
    optional outFields as text    // Optional: Comma-separated list of fields, e.g., "ObjectID,FieldName1,FieldName2". Defaults to all fields '*'.
) as table =>
let
    // --- Documentation ---
    Documentation = [
        Documentation.Name = "fx_GetArcGISLayerData",
        Documentation.Description = "Connects to an ArcGIS REST API Layer (FeatureServer or MapServer) and retrieves feature attributes as a table. WARNING: Does NOT automatically handle pagination; only retrieves the first batch of records based on server limits (typically 1000-2000).",
        Documentation.LongDescription = "Constructs a query URL for the specified ArcGIS service layer, fetches data using Web.Contents, parses the JSON response, and expands the feature attributes into a table. Handles basic error checking for the web request and JSON structure. Remember to configure authentication separately in Power BI's data source settings.",
        Documentation.Category = "Data Access",
        Documentation.Source = "ArcGIS REST API",
        Documentation.Version = "1.0 (Basic - No Pagination)",
        Documentation.Author = "AI Assistant",
        Documentation.Examples = {[
            Description = "Get all fields and records (up to server limit) from Layer 0 of a specific FeatureServer.",
            Code = "fx_GetArcGISLayerData(""https://services1.arcgis.com/ESMARspQHYMw9BZ9/ArcGIS/rest/services/LSOA_2011_to_LSOA_2021_to_Local_Authority_District_2022_Lookup_for_England__2022/FeatureServer"", 0)",
            Result = "Table containing attributes from the first batch of features."
        ],[
            Description = "Get specific fields for features where POPULATION > 10000 from Layer 5 of a MapServer.",
            Code = "fx_GetArcGISLayerData(""https://sampleserver6.arcgisonline.com/arcgis/rest/services/USA/MapServer"", 5, ""POPULATION > 10000"", ""ObjectID,STATE_NAME,POPULATION"")",
            Result = "Table containing ObjectID, STATE_NAME, POPULATION for matching features (up to server limit)."
        ]}
    ],

    // --- Function Logic ---

    // Set defaults for optional parameters
    ActualWhereClause = if whereClause = null or Text.Trim(whereClause) = "" then "1=1" else whereClause,
    ActualOutFields = if outFields = null or Text.Trim(outFields) = "" then "*" else outFields,

    // Construct the base query part of the URL
    BaseLayerUrl = serviceUrl & "/" & Text.From(layerId),

    // Build Query Parameters safely
    QueryParameters = [
        where = ActualWhereClause,
        outFields = ActualOutFields,
        f = "json" // Request JSON format
        // Consider adding resultRecordCount, returnGeometry=false if needed later
    ],

    // Construct the full URL
    FullQueryUrl = BaseLayerUrl & "/query?" & Uri.BuildQueryString(QueryParameters),

    // Fetch data with basic error handling
    SourceJson = try Json.Document(Web.Contents(FullQueryUrl, [Timeout=#duration(0, 0, 5, 0)])) otherwise null, // 5 min timeout

    // Check if the web request or JSON parsing failed
    ResultTable = if SourceJson = null then
        #table({"Error"}, {{"Failed to fetch or parse JSON from URL: " & FullQueryUrl}})
    else if Record.HasFields(SourceJson, "error") then
         // Check if ArcGIS returned an error object
        #table({"ArcGISError"}, {{SourceJson[error]}})
    else if not Record.HasFields(SourceJson, "features") then
         // Check if the expected 'features' field is present
         #table({"Error"}, {{"JSON response did not contain expected 'features' field."}})
    else
        let
            featuresList = SourceJson[features],
            // Check if any features were returned
            OutputTable = if List.IsEmpty(featuresList) then
                 // Return empty table with expected structure (or just empty)
                 // Getting schema requires an extra call or assuming structure based on metadata - simpler to return empty for now.
                 Table.FromList({}, null, {"NoFeaturesReturned"}) // Placeholder column
            else
                let
                     // Convert list of feature records to a table
                    featuresTable = Table.FromList(featuresList, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
                     // Expand the 'attributes' record. Assumes 'attributes' exists in the first feature.
                    AttributeFieldNames = Record.FieldNames(featuresTable{0}[Column1][attributes]),
                    ExpandedAttributes = Table.ExpandRecordColumn(featuresTable, "Column1", {"attributes"}, {"attributes"}),
                    ExpandedData = Table.ExpandRecordColumn(ExpandedAttributes, "attributes", AttributeFieldNames, AttributeFieldNames)
                in
                    ExpandedData
        in
            OutputTable
in
    ResultTable
