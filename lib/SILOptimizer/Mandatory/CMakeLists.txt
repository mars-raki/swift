set(MANDATORY_SOURCES
  Mandatory/AccessEnforcementSelection.cpp
  Mandatory/AccessMarkerElimination.cpp
  Mandatory/AddressLowering.cpp
  Mandatory/DefiniteInitialization.cpp
  Mandatory/DIMemoryUseCollector.cpp
  Mandatory/DIMemoryUseCollectorOwnership.cpp
  Mandatory/DataflowDiagnostics.cpp
  Mandatory/DiagnoseInfiniteRecursion.cpp
  Mandatory/DiagnoseStaticExclusivity.cpp
  Mandatory/DiagnoseUnreachable.cpp
  Mandatory/GuaranteedARCOpts.cpp
  Mandatory/MandatoryInlining.cpp
  Mandatory/PredictableMemOpt.cpp
  Mandatory/ConstantPropagation.cpp
  Mandatory/SemanticARCOpts.cpp
  # SWIFT_ENABLE_TENSORFLOW
  Mandatory/TFDifferentiation.cpp
  Mandatory/TFCanonicalizeCFG.cpp
  Mandatory/TFConstExpr.cpp
  Mandatory/TFDeabstraction.cpp
  Mandatory/TFDevicePartition.cpp
  Mandatory/TFLowerGraph.cpp
  Mandatory/TFPartition.cpp
  Mandatory/TFUtilities.cpp
  PARENT_SCOPE)
