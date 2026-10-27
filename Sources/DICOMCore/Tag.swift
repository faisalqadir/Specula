import Foundation

/// A DICOM attribute tag (group, element).
public struct Tag: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    @inlinable public init(_ group: UInt16, _ element: UInt16) {
        raw = (UInt32(group) << 16) | UInt32(element)
    }

    @inlinable public init(raw: UInt32) { self.raw = raw }

    /// Parses "(0010,0010)", "0010,0010" or "00100010".
    public init?(string: String) {
        let hex = string.filter { $0.isHexDigit }
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { return nil }
        raw = v
    }

    @inlinable public var group: UInt16 { UInt16(truncatingIfNeeded: raw >> 16) }
    @inlinable public var element: UInt16 { UInt16(truncatingIfNeeded: raw) }
    public var isPrivate: Bool { group & 1 == 1 && group > 0x0008 }
    public var isPrivateCreator: Bool { isPrivate && element >= 0x0010 && element <= 0x00FF }
    public var isGroupLength: Bool { element == 0 }

    public var description: String { String(format: "(%04X,%04X)", group, element) }
    public var hex: String { String(format: "%04X%04X", group, element) }

    public static func < (a: Tag, b: Tag) -> Bool { a.raw < b.raw }

    // Item delimiters
    public static let item = Tag(0xFFFE, 0xE000)
    public static let itemDelimitation = Tag(0xFFFE, 0xE00D)
    public static let sequenceDelimitation = Tag(0xFFFE, 0xE0DD)

    // File meta
    public static let fileMetaInformationGroupLength = Tag(0x0002, 0x0000)
    public static let fileMetaInformationVersion = Tag(0x0002, 0x0001)
    public static let mediaStorageSOPClassUID = Tag(0x0002, 0x0002)
    public static let mediaStorageSOPInstanceUID = Tag(0x0002, 0x0003)
    public static let transferSyntaxUID = Tag(0x0002, 0x0010)
    public static let implementationClassUID = Tag(0x0002, 0x0012)
    public static let implementationVersionName = Tag(0x0002, 0x0013)
    public static let sourceApplicationEntityTitle = Tag(0x0002, 0x0016)

    // Patient / study / series / instance
    public static let specificCharacterSet = Tag(0x0008, 0x0005)
    public static let imageType = Tag(0x0008, 0x0008)
    public static let sopClassUID = Tag(0x0008, 0x0016)
    public static let sopInstanceUID = Tag(0x0008, 0x0018)
    public static let studyDate = Tag(0x0008, 0x0020)
    public static let seriesDate = Tag(0x0008, 0x0021)
    public static let acquisitionDate = Tag(0x0008, 0x0022)
    public static let contentDate = Tag(0x0008, 0x0023)
    public static let acquisitionDateTime = Tag(0x0008, 0x002A)
    public static let studyTime = Tag(0x0008, 0x0030)
    public static let seriesTime = Tag(0x0008, 0x0031)
    public static let acquisitionTime = Tag(0x0008, 0x0032)
    public static let contentTime = Tag(0x0008, 0x0033)
    public static let accessionNumber = Tag(0x0008, 0x0050)
    public static let queryRetrieveLevel = Tag(0x0008, 0x0052)
    public static let retrieveAETitle = Tag(0x0008, 0x0054)
    public static let modality = Tag(0x0008, 0x0060)
    public static let modalitiesInStudy = Tag(0x0008, 0x0061)
    public static let manufacturer = Tag(0x0008, 0x0070)
    public static let institutionName = Tag(0x0008, 0x0080)
    public static let referringPhysicianName = Tag(0x0008, 0x0090)
    public static let stationName = Tag(0x0008, 0x1010)
    public static let studyDescription = Tag(0x0008, 0x1030)
    public static let seriesDescription = Tag(0x0008, 0x103E)
    public static let performingPhysicianName = Tag(0x0008, 0x1050)
    public static let nameOfPhysiciansReadingStudy = Tag(0x0008, 0x1060)
    public static let operatorsName = Tag(0x0008, 0x1070)
    public static let manufacturerModelName = Tag(0x0008, 0x1090)
    public static let referencedImageSequence = Tag(0x0008, 0x1140)
    public static let derivationDescription = Tag(0x0008, 0x2111)
    public static let lossyImageCompression = Tag(0x0028, 0x2110)
    public static let lossyImageCompressionRatio = Tag(0x0028, 0x2112)
    public static let lossyImageCompressionMethod = Tag(0x0028, 0x2114)

    public static let patientName = Tag(0x0010, 0x0010)
    public static let patientID = Tag(0x0010, 0x0020)
    public static let patientBirthDate = Tag(0x0010, 0x0030)
    public static let patientSex = Tag(0x0010, 0x0040)
    public static let patientAge = Tag(0x0010, 0x1010)
    public static let patientSize = Tag(0x0010, 0x1020)
    public static let patientWeight = Tag(0x0010, 0x1030)

    public static let bodyPartExamined = Tag(0x0018, 0x0015)
    public static let sliceThickness = Tag(0x0018, 0x0050)
    public static let kvp = Tag(0x0018, 0x0060)
    public static let spacingBetweenSlices = Tag(0x0018, 0x0088)
    public static let repetitionTime = Tag(0x0018, 0x0080)
    public static let echoTime = Tag(0x0018, 0x0081)
    public static let magneticFieldStrength = Tag(0x0018, 0x0087)
    public static let protocolName = Tag(0x0018, 0x1030)
    public static let frameTime = Tag(0x0018, 0x1063)
    public static let cineRate = Tag(0x0018, 0x0040)
    public static let recommendedDisplayFrameRate = Tag(0x0008, 0x2144)
    public static let frameTimeVector = Tag(0x0018, 0x1065)
    public static let xRayTubeCurrent = Tag(0x0018, 0x1151)
    public static let exposure = Tag(0x0018, 0x1152)
    public static let imagerPixelSpacing = Tag(0x0018, 0x1164)
    public static let positionerPrimaryAngle = Tag(0x0018, 0x1510)
    public static let positionerSecondaryAngle = Tag(0x0018, 0x1511)
    public static let viewPosition = Tag(0x0018, 0x5101)
    public static let sequenceOfUltrasoundRegions = Tag(0x0018, 0x6011)
    public static let physicalDeltaX = Tag(0x0018, 0x602C)
    public static let physicalDeltaY = Tag(0x0018, 0x602E)
    public static let physicalUnitsXDirection = Tag(0x0018, 0x6024)
    public static let physicalUnitsYDirection = Tag(0x0018, 0x6026)
    public static let estimatedRadiographicMagnificationFactor = Tag(0x0018, 0x1114)

    public static let studyInstanceUID = Tag(0x0020, 0x000D)
    public static let seriesInstanceUID = Tag(0x0020, 0x000E)
    public static let studyID = Tag(0x0020, 0x0010)
    public static let seriesNumber = Tag(0x0020, 0x0011)
    public static let acquisitionNumber = Tag(0x0020, 0x0012)
    public static let instanceNumber = Tag(0x0020, 0x0013)
    public static let patientOrientation = Tag(0x0020, 0x0020)
    public static let imagePositionPatient = Tag(0x0020, 0x0032)
    public static let imageOrientationPatient = Tag(0x0020, 0x0037)
    public static let frameOfReferenceUID = Tag(0x0020, 0x0052)
    public static let imageLaterality = Tag(0x0020, 0x0062)
    public static let temporalPositionIdentifier = Tag(0x0020, 0x0100)
    public static let numberOfTemporalPositions = Tag(0x0020, 0x0105)
    public static let sliceLocation = Tag(0x0020, 0x1041)
    public static let imageComments = Tag(0x0020, 0x4000)
    public static let numberOfStudyRelatedSeries = Tag(0x0020, 0x1206)
    public static let numberOfStudyRelatedInstances = Tag(0x0020, 0x1208)
    public static let numberOfSeriesRelatedInstances = Tag(0x0020, 0x1209)

    public static let samplesPerPixel = Tag(0x0028, 0x0002)
    public static let photometricInterpretation = Tag(0x0028, 0x0004)
    public static let planarConfiguration = Tag(0x0028, 0x0006)
    public static let numberOfFrames = Tag(0x0028, 0x0008)
    public static let frameIncrementPointer = Tag(0x0028, 0x0009)
    public static let rows = Tag(0x0028, 0x0010)
    public static let columns = Tag(0x0028, 0x0011)
    public static let pixelSpacing = Tag(0x0028, 0x0030)
    public static let pixelAspectRatio = Tag(0x0028, 0x0034)
    public static let bitsAllocated = Tag(0x0028, 0x0100)
    public static let bitsStored = Tag(0x0028, 0x0101)
    public static let highBit = Tag(0x0028, 0x0102)
    public static let pixelRepresentation = Tag(0x0028, 0x0103)
    public static let smallestImagePixelValue = Tag(0x0028, 0x0106)
    public static let largestImagePixelValue = Tag(0x0028, 0x0107)
    public static let pixelPaddingValue = Tag(0x0028, 0x0120)
    public static let pixelPaddingRangeLimit = Tag(0x0028, 0x0121)
    public static let windowCenter = Tag(0x0028, 0x1050)
    public static let windowWidth = Tag(0x0028, 0x1051)
    public static let rescaleIntercept = Tag(0x0028, 0x1052)
    public static let rescaleSlope = Tag(0x0028, 0x1053)
    public static let rescaleType = Tag(0x0028, 0x1054)
    public static let windowCenterWidthExplanation = Tag(0x0028, 0x1055)
    public static let voiLUTFunction = Tag(0x0028, 0x1056)
    public static let redPaletteColorLookupTableDescriptor = Tag(0x0028, 0x1101)
    public static let greenPaletteColorLookupTableDescriptor = Tag(0x0028, 0x1102)
    public static let bluePaletteColorLookupTableDescriptor = Tag(0x0028, 0x1103)
    public static let redPaletteColorLookupTableData = Tag(0x0028, 0x1201)
    public static let greenPaletteColorLookupTableData = Tag(0x0028, 0x1202)
    public static let bluePaletteColorLookupTableData = Tag(0x0028, 0x1203)
    public static let segmentedRedPaletteColorLookupTableData = Tag(0x0028, 0x1221)
    public static let segmentedGreenPaletteColorLookupTableData = Tag(0x0028, 0x1222)
    public static let segmentedBluePaletteColorLookupTableData = Tag(0x0028, 0x1223)
    public static let modalityLUTSequence = Tag(0x0028, 0x3000)
    public static let lutDescriptor = Tag(0x0028, 0x3002)
    public static let lutExplanation = Tag(0x0028, 0x3003)
    public static let modalityLUTType = Tag(0x0028, 0x3004)
    public static let lutData = Tag(0x0028, 0x3006)
    public static let voiLUTSequence = Tag(0x0028, 0x3010)
    public static let extendedOffsetTable = Tag(0x7FE0, 0x0001)
    public static let extendedOffsetTableLengths = Tag(0x7FE0, 0x0002)
    public static let floatPixelData = Tag(0x7FE0, 0x0008)
    public static let doubleFloatPixelData = Tag(0x7FE0, 0x0009)
    public static let pixelData = Tag(0x7FE0, 0x0010)

    // Enhanced multi-frame functional groups
    public static let sharedFunctionalGroupsSequence = Tag(0x5200, 0x9229)
    public static let perFrameFunctionalGroupsSequence = Tag(0x5200, 0x9230)
    public static let pixelMeasuresSequence = Tag(0x0028, 0x9110)
    public static let planePositionSequence = Tag(0x0020, 0x9113)
    public static let planeOrientationSequence = Tag(0x0020, 0x9116)
    public static let frameVOILUTSequence = Tag(0x0028, 0x9132)
    public static let pixelValueTransformationSequence = Tag(0x0028, 0x9145)
    public static let frameContentSequence = Tag(0x0020, 0x9111)
    public static let inStackPositionNumber = Tag(0x0020, 0x9057)
    public static let temporalPositionIndex = Tag(0x0020, 0x9128)
    public static let dimensionIndexValues = Tag(0x0020, 0x9157)
    public static let frameAcquisitionDateTime = Tag(0x0018, 0x9074)

    // PET / NM
    public static let units = Tag(0x0054, 0x1001)
    public static let decayCorrection = Tag(0x0054, 0x1102)
    public static let radiopharmaceuticalInformationSequence = Tag(0x0054, 0x0016)
    public static let radiopharmaceuticalStartTime = Tag(0x0018, 0x1072)
    public static let radiopharmaceuticalStartDateTime = Tag(0x0018, 0x1078)
    public static let radionuclideTotalDose = Tag(0x0018, 0x1074)
    public static let radionuclideHalfLife = Tag(0x0018, 0x1075)
    public static let correctedImage = Tag(0x0028, 0x0051)

    // Overlay (group 60xx)
    public static func overlay(_ index: Int, _ element: UInt16) -> Tag { Tag(UInt16(0x6000 + 2 * index), element) }

    // DICOMDIR
    public static let directoryRecordSequence = Tag(0x0004, 0x1220)
    public static let directoryRecordType = Tag(0x0004, 0x1430)
    public static let referencedFileID = Tag(0x0004, 0x1500)
    public static let offsetOfTheNextDirectoryRecord = Tag(0x0004, 0x1400)
    public static let offsetOfReferencedLowerLevelDirectoryEntity = Tag(0x0004, 0x1420)
    public static let offsetOfTheFirstDirectoryRecordOfTheRootDirectoryEntity = Tag(0x0004, 0x1200)
    public static let referencedSOPInstanceUIDInFile = Tag(0x0004, 0x1511)
    public static let referencedTransferSyntaxUIDInFile = Tag(0x0004, 0x1512)

    // SR / encapsulated documents
    public static let encapsulatedDocument = Tag(0x0042, 0x0011)
    public static let mimeTypeOfEncapsulatedDocument = Tag(0x0042, 0x0012)
    public static let documentTitle = Tag(0x0042, 0x0010)
    public static let contentSequence = Tag(0x0040, 0xA730)
    public static let conceptNameCodeSequence = Tag(0x0040, 0xA043)
    public static let valueType = Tag(0x0040, 0xA040)
    public static let textValue = Tag(0x0040, 0xA160)
    public static let codeMeaning = Tag(0x0008, 0x0104)
    public static let codeValue = Tag(0x0008, 0x0100)
    public static let codingSchemeDesignator = Tag(0x0008, 0x0102)
    public static let conceptCodeSequence = Tag(0x0040, 0xA168)
    public static let measuredValueSequence = Tag(0x0040, 0xA300)
    public static let numericValue = Tag(0x0040, 0xA30A)
    public static let measurementUnitsCodeSequence = Tag(0x0040, 0x08EA)
    public static let relationshipType = Tag(0x0040, 0xA010)
    public static let completionFlag = Tag(0x0040, 0xA491)
    public static let verificationFlag = Tag(0x0040, 0xA493)
    public static let personName = Tag(0x0040, 0xA123)
    public static let dateValue = Tag(0x0040, 0xA121)
    public static let timeValue = Tag(0x0040, 0xA122)
    public static let dateTimeValue = Tag(0x0040, 0xA120)
    public static let uidValue = Tag(0x0040, 0xA124)
    public static let referencedSOPSequence = Tag(0x0008, 0x1199)
    public static let referencedSOPClassUID = Tag(0x0008, 0x1150)
    public static let referencedSOPInstanceUID = Tag(0x0008, 0x1155)

    // Patient attributes for anonymisation
    public static let otherPatientIDs = Tag(0x0010, 0x1000)
    public static let otherPatientNames = Tag(0x0010, 0x1001)
    public static let patientAddress = Tag(0x0010, 0x1040)
    public static let patientTelephoneNumbers = Tag(0x0010, 0x2154)
    public static let institutionAddress = Tag(0x0008, 0x0081)
    public static let deviceSerialNumber = Tag(0x0018, 0x1000)
}
