(URL) =>
let
    /* Define the binary format structure for ZIP file header components */
    Header = BinaryFormat.Record([
        MiscHeader = BinaryFormat.Binary(14),             // First 14 bytes (signature, version, flags, etc.)
        BinarySize = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),  // Compressed size (4 bytes)
        FileSize   = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),  // Uncompressed size (4 bytes)
        FileNameLen= BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.LittleEndian),  // Filename length (2 bytes)
        ExtrasLen  = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.LittleEndian)   // Extra field length (2 bytes)
    ]),
 
    /* Parse each file entry in the ZIP archive */
    HeaderChoice = BinaryFormat.Choice(
        BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),
        each if _ <> 67324752             // 67324752 (0x04034B50) is the ZIP local file header signature
            then BinaryFormat.Record([IsValid = false, Filename=null, Content=null])  // Invalid signature
            else BinaryFormat.Choice(
                    BinaryFormat.Binary(26),      // Process the 26-byte header (14+4+4+2+2)
                    each BinaryFormat.Record([
                        IsValid  = true,
                        Filename = BinaryFormat.Text(Header(_)[FileNameLen]),         // Extract filename based on specified length
                        Extras   = BinaryFormat.Text(Header(_)[ExtrasLen]),           // Extract extras based on specified length
                        Content  = BinaryFormat.Transform(
                            BinaryFormat.Binary(Header(_)[BinarySize]),               // Get binary content based on compressed size
                            (x) => try Binary.Buffer(Binary.Decompress(x, Compression.Deflate)) otherwise null  // Decompress content
                        )
                        ]),
                        type binary                   // Enable streaming for large files
                )
    ),
 
    /* Create a list format that parses multiple ZIP entries */
    ZipFormat = BinaryFormat.List(HeaderChoice, each _[IsValid] = true),
 
    /* Process the ZIP file and extract files into a clean list structure */
    Entries = List.Transform(
        List.RemoveLastN( ZipFormat(Binary.Buffer(Web.Contents(URL))), 1),  // Remove last entry (often a marker)
        (e) => [FileName = e[Filename], Content = e[Content] ]              // Keep only relevant fields
    )
in
    Table.FromRecords(Entries)  // Convert the list of records to a table
