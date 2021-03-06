{- Stephan Fuchs EVE Online mining bot version 2020-10-31
   Merge as described at https://forum.botengine.org/t/eve-online-request-suggestion/3663
   Merged change to drones from app https://catalog.botengine.org/813iHfbf1q7yRneJPNzxGTWEZRtMHyitqxb42a81dddd0e992a0d9db1fce92da2
-}
{-
   app-catalog-tags:eve-online,mining
   authors-forum-usernames:viir
-}


module BotEngineApp exposing
    ( State
    , initState
    , processEvent
    )

import BotEngine.Interface_To_Host_20200824 as InterfaceToHost
import Common.AppSettings as AppSettings
import Common.Basics exposing (listElementAtWrappedIndex)
import Common.DecisionTree exposing (describeBranch, endDecisionPath)
import Common.EffectOnWindow as EffectOnWindow exposing (MouseButton(..))
import Dict
import EveOnline.AppFramework
    exposing
        ( AppEffect(..)
        , DecisionPathNode
        , EndDecisionPathStructure(..)
        , ReadingFromGameClient
        , SeeUndockingComplete
        , ShipModulesMemory
        , UIElement
        , actWithoutFurtherReadings
        , askForHelpToGetUnstuck
        , branchDependingOnDockedOrInSpace
        , clickOnUIElement
        , infoPanelRouteFirstMarkerFromReadingFromGameClient
        , doEffectsClickModuleButton
        , ensureInfoPanelLocationInfoIsExpanded
        , getEntropyIntFromReadingFromGameClient
        , localChatWindowFromUserInterface
        , menuCascadeCompleted
        , shipUIIndicatesShipIsWarpingOrJumping
        , useContextMenuCascade
        , useContextMenuCascadeOnListSurroundingsButton
        , useContextMenuCascadeOnOverviewEntry
        , useMenuEntryInLastContextMenuInCascade
        , useMenuEntryWithTextContaining
        , useMenuEntryWithTextContainingFirstOf
        , useMenuEntryWithTextEqual
        , useRandomMenuEntry
        , waitForProgressInGame
        )
import EveOnline.ParseUserInterface
    exposing
        ( OverviewWindowEntry
        , centerFromDisplayRegion
        , getAllContainedDisplayTexts
        , getSubstringBetweenXmlTagsAfterMarker
        )
import Regex


{-| Sources for the defaults:
  - <https://forum.botengine.org/t/mining-bot-wont-approach/3162>
-}
defaultBotSettings : BotSettings
defaultBotSettings =
    { runAwayShieldHitpointsThresholdPercent = 30
    , unloadStationName = Nothing
    , unloadStructureName = Nothing
    , modulesToActivateAlways = []
    , hideWhenNeutralInLocal = Nothing
    , targetingRange = 8000
    , miningModuleRange = 5000
    , botStepDelayMilliseconds = 1500
    , oreHoldMaxPercent = 95
    , selectInstancePilotName = Nothing
    }


parseBotSettings : String -> Result String BotSettings
parseBotSettings =
    AppSettings.parseSimpleListOfAssignments { assignmentsSeparators = [ ",", "\n" ] }
        ([ ( "run-away-shield-hitpoints-threshold-percent"
           , AppSettings.valueTypeInteger (\threshold settings -> { settings | runAwayShieldHitpointsThresholdPercent = threshold })
           )
         , ( "unload-station-name"
           , AppSettings.valueTypeString (\stationName -> \settings -> { settings | unloadStationName = Just stationName })
           )
         , ( "unload-structure-name"
           , AppSettings.valueTypeString (\structureName -> \settings -> { settings | unloadStructureName = Just structureName })
           )
         , ( "module-to-activate-always"
           , AppSettings.valueTypeString (\moduleName -> \settings -> { settings | modulesToActivateAlways = moduleName :: settings.modulesToActivateAlways })
           )
         , ( "hide-when-neutral-in-local"
           , AppSettings.valueTypeYesOrNo
                (\hide -> \settings -> { settings | hideWhenNeutralInLocal = Just hide })
           )
         , ( "targeting-range"
           , AppSettings.valueTypeInteger (\range settings -> { settings | targetingRange = range })
           )
         , ( "mining-module-range"
           , AppSettings.valueTypeInteger (\range settings -> { settings | miningModuleRange = range })
           )
         , ( "ore-hold-max-percent"
           , AppSettings.valueTypeInteger (\percent settings -> { settings | oreHoldMaxPercent = percent })
           )
         , ( "select-instance-pilot-name"
           , AppSettings.valueTypeString (\pilotName -> \settings -> { settings | selectInstancePilotName = Just pilotName })
           )
         , ( "bot-step-delay"
           , AppSettings.valueTypeInteger (\delay settings -> { settings | botStepDelayMilliseconds = delay })
           )
         ]
            |> Dict.fromList
        )
        defaultBotSettings


goodStandingPatterns : List String
goodStandingPatterns =
    [ "good standing", "excellent standing", "is in your" ]


type alias BotSettings =
    { runAwayShieldHitpointsThresholdPercent : Int
    , unloadStationName : Maybe String
    , unloadStructureName : Maybe String
    , modulesToActivateAlways : List String
    , hideWhenNeutralInLocal : Maybe AppSettings.YesOrNo
    , targetingRange : Int
    , miningModuleRange : Int
    , botStepDelayMilliseconds : Int
    , oreHoldMaxPercent : Int
    , selectInstancePilotName : Maybe String
    }


type alias BotMemory =
    { lastDockedStationNameFromInfoPanel : Maybe String
    , timesUnloaded : Int
    , volumeUnloadedCubicMeters : Int
    , lastUsedCapacityInOreHold : Maybe Int
    , shipModules : ShipModulesMemory
    }


type alias BotDecisionContext =
    EveOnline.AppFramework.StepDecisionContext BotSettings BotMemory


type alias BotState =
    EveOnline.AppFramework.AppStateWithMemoryAndDecisionTree BotMemory


type alias State =
    EveOnline.AppFramework.StateIncludingFramework BotSettings BotState


{-| A first outline of the decision tree for a mining bot came from <https://forum.botengine.org/t/how-to-automate-mining-asteroids-in-eve-online/628/109?u=viir>
-}
miningBotDecisionRoot : BotDecisionContext -> DecisionPathNode
miningBotDecisionRoot context =
    generalSetupInUserInterface context.readingFromGameClient
        |> Maybe.withDefault
            (branchDependingOnDockedOrInSpace
                { ifDocked =
                    (case context.readingFromGameClient |> inventoryWindowWithItemHangarSelectedFromGameClient of
                        Just inventoryWindow ->
                            (ensureItemHangarIsSelectedInInventoryWindow
                                context
                                (dockedWithItemHangarSelected context)
                            )

                        Nothing ->
                            (ensureOreHoldIsSelectedInInventoryWindow
                                context
                                (dockedWithOreHoldSelected context)
                            )
                    )
                    
                , ifSeeShipUI =
                    returnDronesAndRunAwayIfHitpointsAreTooLow context
                , ifUndockingComplete =
                    \seeUndockingComplete ->
                        continueIfShouldHide
                            { ifShouldHide =
                                returnDronesToBay context.readingFromGameClient
                                    |> Maybe.withDefault (dockToUnloadOre context)
                            }
                            context
                            |> Maybe.withDefault
                                (case context.readingFromGameClient |> inventoryWindowWithOreHoldSelectedFromGameClient of
                                    Just inventoryWindow ->
                                        (ensureOreHoldIsSelectedInInventoryWindow
                                            context
                                            (inSpaceWithOreHoldSelected context seeUndockingComplete)
                                        )

                                    Nothing ->

                                        (ensureFleetHangarIsSelectedInInventoryWindow
                                            context
                                            (inSpaceWithFleetHangarSelected context seeUndockingComplete)
                                        )
                                
                                )
                }
                context.readingFromGameClient
            )


continueIfShouldHide : { ifShouldHide : DecisionPathNode } -> BotDecisionContext -> Maybe DecisionPathNode
continueIfShouldHide config context =
    if not (context |> shouldHideWhenNeutralInLocal) then
        Nothing

    else
        case context.readingFromGameClient |> localChatWindowFromUserInterface of
            Nothing ->
                Just (describeBranch "I don't see the local chat window." askForHelpToGetUnstuck)

            Just localChatWindow ->
                let
                    chatUserHasGoodStanding chatUser =
                        goodStandingPatterns
                            |> List.any
                                (\goodStandingPattern ->
                                    chatUser.standingIconHint
                                        |> Maybe.map (String.toLower >> String.contains goodStandingPattern)
                                        |> Maybe.withDefault False
                                )

                    subsetOfUsersWithNoGoodStanding =
                        localChatWindow.userlist
                            |> Maybe.map .visibleUsers
                            |> Maybe.withDefault []
                            |> List.filter (chatUserHasGoodStanding >> not)
                in
                if 1 < (subsetOfUsersWithNoGoodStanding |> List.length) then
                    Just (describeBranch "There is an enemy or neutral in local chat." config.ifShouldHide)

                else
                    Nothing


shouldHideWhenNeutralInLocal : BotDecisionContext -> Bool
shouldHideWhenNeutralInLocal context =
    case context.eventContext.appSettings.hideWhenNeutralInLocal of
        Just AppSettings.No ->
            False

        Just AppSettings.Yes ->
            True

        Nothing ->
            (context.readingFromGameClient.infoPanelContainer
                |> Maybe.andThen .infoPanelLocationInfo
                |> Maybe.andThen .securityStatusPercent
                |> Maybe.withDefault 0
            )
                < 50


returnDronesAndRunAwayIfHitpointsAreTooLow : BotDecisionContext -> EveOnline.ParseUserInterface.ShipUI -> Maybe DecisionPathNode
returnDronesAndRunAwayIfHitpointsAreTooLow context shipUI =
    let
        returnDronesShieldHitpointsThresholdPercent =
            context.eventContext.appSettings.runAwayShieldHitpointsThresholdPercent + 5

        runAwayWithDescription =
            describeBranch
                ("Shield hitpoints are at " ++ (shipUI.hitpointsPercent.shield |> String.fromInt) ++ "%. Run away.")
                (runAway context)
    in
    if shipUI.hitpointsPercent.shield < context.eventContext.appSettings.runAwayShieldHitpointsThresholdPercent then
        Just runAwayWithDescription

    else if shipUI.hitpointsPercent.shield < returnDronesShieldHitpointsThresholdPercent then
        returnDronesToBay context.readingFromGameClient
            |> Maybe.map
                (describeBranch
                    ("Shield hitpoints are below " ++ (returnDronesShieldHitpointsThresholdPercent |> String.fromInt) ++ "%. Return drones.")
                )
            |> Maybe.withDefault runAwayWithDescription
            |> Just

    else
        Nothing


generalSetupInUserInterface : ReadingFromGameClient -> Maybe DecisionPathNode
generalSetupInUserInterface readingFromGameClient =
    [ closeMessageBox, closeHybridWindow, ensureInfoPanelLocationInfoIsExpanded ]
        |> List.filterMap
            (\maybeSetupDecisionFromGameReading ->
                maybeSetupDecisionFromGameReading readingFromGameClient
            )
        |> List.head


closeMessageBox : ReadingFromGameClient -> Maybe DecisionPathNode
closeMessageBox readingFromGameClient =
    readingFromGameClient.messageBoxes
        |> List.head
        |> Maybe.map
            (\messageBox ->
                describeBranch "I see a message box to close."
                    (let
                        buttonCanBeUsedToClose =
                            .mainText
                                >> Maybe.map (String.trim >> String.toLower >> (\buttonText -> [ "close", "ok", "yes" ] |> List.member buttonText))
                                >> Maybe.withDefault False
                     in
                     case messageBox.buttons |> List.filter buttonCanBeUsedToClose |> List.head of
                        Nothing ->
                            describeBranch "I see no way to close this message box." askForHelpToGetUnstuck

                        Just buttonToUse ->
                            endDecisionPath
                                (actWithoutFurtherReadings
                                    ( "Click on button '" ++ (buttonToUse.mainText |> Maybe.withDefault "") ++ "'."
                                    , buttonToUse.uiNode |> clickOnUIElement MouseButtonLeft
                                    )
                                )
                    )
            )

closeHybridWindow : ReadingFromGameClient -> Maybe DecisionPathNode
closeHybridWindow readingFromGameClient =
    readingFromGameClient.hybridWindows
        |> List.head
        |> Maybe.map
            (\hybridWindow ->
                describeBranch "I see a hybrid window to close."
                    (let
                        buttonCanBeUsedToClose =
                            .mainText
                                >> Maybe.map (String.trim >> String.toLower >> (\buttonText -> [ "close", "ok" ] |> List.member buttonText))
                                >> Maybe.withDefault False
                     in
                     case hybridWindow.buttons |> List.filter buttonCanBeUsedToClose |> List.head of
                        Nothing ->
                            describeBranch "I see no way to close this hybrid window." askForHelpToGetUnstuck

                        Just buttonToUse ->
                            endDecisionPath
                                (actWithoutFurtherReadings
                                    ( "Click on button '" ++ (buttonToUse.mainText |> Maybe.withDefault "") ++ "'."
                                    , buttonToUse.uiNode |> clickOnUIElement MouseButtonLeft
                                    )
                                )
                    )
            )

dockedWithOreHoldSelected : BotDecisionContext -> EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode
dockedWithOreHoldSelected context inventoryWindowWithOreHoldSelected =
    case inventoryWindowWithOreHoldSelected |> itemHangarFromInventoryWindow of
        Nothing ->
            describeBranch "I do not see the item hangar in the inventory." askForHelpToGetUnstuck

        Just itemHangar ->
            case inventoryWindowWithOreHoldSelected |> selectedContainerFirstItemFromInventoryWindow of
                Nothing ->
                    describeBranch "I see no item in the ore hold. Check if we should undock."
                        (continueIfShouldHide
                            { ifShouldHide =
                                describeBranch "Stay docked." waitForProgressInGame
                            }
                            context
                            |> Maybe.withDefault (undockUsingStationWindow context)
                        )

                Just itemInInventory ->
                    let
                        allItemsSelected =
                            inventoryWindowWithOreHoldSelected.uiNode.uiNode
                                |> getAllContainedDisplayTexts
                                |> List.filter (String.toLower >> String.contains "/")
                                |> List.head
                    in
                    case allItemsSelected of
                        Nothing ->
                            describeBranch "Select all ore items to drag into item hangar"
                                (useContextMenuCascade
                                    ( "Item Hangar", itemInInventory )
                                        (useMenuEntryWithTextContaining "Select All" menuCascadeCompleted)
                                    context.readingFromGameClient
                                )
                        Just allItems ->
                            describeBranch "I see at least one item in the ore hold. Move this to the item hangar."
                                (endDecisionPath
                                    (actWithoutFurtherReadings
                                        ( "Drag and drop."
                                        , EffectOnWindow.effectsForDragAndDrop
                                            { startLocation = itemInInventory.totalDisplayRegion |> centerFromDisplayRegion
                                            , endLocation = itemHangar.totalDisplayRegion |> centerFromDisplayRegion
                                            , mouseButton = MouseButtonLeft
                                            }
                                        )
                                    )
                                )


dockedWithItemHangarSelected : BotDecisionContext -> EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode
dockedWithItemHangarSelected context inventoryWindowWithItemHangarSelected =
    case inventoryWindowWithItemHangarSelected |> itemHangarFromInventoryWindow of
        Nothing ->
            describeBranch "I do not see the item hangar in the inventory." askForHelpToGetUnstuck

        Just itemHangar ->
            let
                numberOfInventoryItems =
                    -- inventoryWindowWithItemHangarSelected.uiNode.uiNode
                    --     |> List.filter (.uiNode >> EveOnline.ParseUserInterface.getAllContainedDisplayTexts >> List.any (String.toLower >> String.contains "items"))
                    inventoryWindowWithItemHangarSelected.uiNode.uiNode
                        |> getAllContainedDisplayTexts
                        |> List.filter (String.toLower >> String.contains "<color=gray>items")
                        |> List.head
            in
            case numberOfInventoryItems of
                Nothing ->
                    describeBranch ("Cannot find <color=gray>items.") askForHelpToGetUnstuck
                Just numberOfItems ->
                   case (String.split " " numberOfItems |> List.head) of
                        Nothing ->
                            describeBranch ("Cannot find inventory count.") askForHelpToGetUnstuck
                        Just actualCount ->
                                case (String.toInt actualCount) of
                                    Nothing ->
                                        describeBranch ("No integer found.") askForHelpToGetUnstuck
                                    Just actualInteger ->
                                        if (actualInteger > 100) then
                                            case inventoryWindowWithItemHangarSelected |> selectedContainerFirstItemFromInventoryWindow of
                                                Nothing ->
                                                    describeBranch ("I see no item in the item hangar. Select fleet hangar." ++ actualCount)
                                                        (continueIfShouldHide
                                                            { ifShouldHide =
                                                                describeBranch "Stay docked." waitForProgressInGame
                                                            }
                                                            context
                                                            |> Maybe.withDefault (undockUsingStationWindow context)
                                                        )

                                                Just itemInInventory ->
                                                    describeBranch "I see at least 100 items in the item hangar. Stack them."
                                                        (useContextMenuCascade
                                                            ( "Item Hangar", itemInInventory )
                                                                (useMenuEntryWithTextContaining "Stack All" menuCascadeCompleted)
                                                            context.readingFromGameClient
                                                        )
                                                
                                        else
                                            describeBranch ("Stacking not required. Switch to Ore Hold.")
                                                (ensureOreHoldIsSelectedInInventoryWindow
                                                    context
                                                    (dockedWithOreHoldSelected context)
                                                )

undockUsingStationWindow : BotDecisionContext -> DecisionPathNode
undockUsingStationWindow context =
    case context.readingFromGameClient.stationWindow of
        Nothing ->
            describeBranch "I do not see the station window." askForHelpToGetUnstuck

        Just stationWindow ->
            case stationWindow.undockButton of
                Nothing ->
                    case stationWindow.abortUndockButton of
                        Nothing ->
                            describeBranch "I do not see the undock button." askForHelpToGetUnstuck

                        Just _ ->
                            describeBranch "I see we are already undocking." waitForProgressInGame

                Just undockButton ->
                    endDecisionPath
                        (actWithoutFurtherReadings
                            ( "Click on the button to undock."
                            , clickOnUIElement MouseButtonLeft undockButton
                            )
                        )


inSpaceWithOreHoldSelected : BotDecisionContext -> SeeUndockingComplete -> EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode
inSpaceWithOreHoldSelected context seeUndockingComplete inventoryWindowWithOreHoldSelected =
    if seeUndockingComplete.shipUI |> shipUIIndicatesShipIsWarpingOrJumping then
        describeBranch "I see we are warping."
            ([ returnDronesToBay context.readingFromGameClient
             , readShipUIModuleButtonTooltips context
             ]
                |> List.filterMap identity
                |> List.head
                |> Maybe.withDefault waitForProgressInGame
            )

    else
        case context.readingFromGameClient.fleetWindow of
            Nothing ->
                describeBranch "Fleet window not open. Wait." waitForProgressInGame
            Just fleetWindow ->
                case context.readingFromGameClient.watchListPanel of
                    Nothing ->
                        describeBranch "Watch List not open. Open it."
                            (case context.readingFromGameClient.fleetWindow |> Maybe.andThen (.fleetMembers >> List.head) of
                                Just fleetMembers ->
                                    (useContextMenuCascade
                                        ( "Fleet destination", fleetMembers )
                                        (useMenuEntryWithTextContaining "Watch List" menuCascadeCompleted)
                                        context.readingFromGameClient
                                    )

                                Nothing ->
                                    describeBranch ("Fleet is not formed. Please take remedial action.") askForHelpToGetUnstuck
                            )

                    Just watchList ->
                        case context.readingFromGameClient |> infoPanelRouteFirstMarkerFromReadingFromGameClient of
                            Just infoPanelRouteFirstMarker ->
                                useContextMenuCascade
                                    ( "route element icon", infoPanelRouteFirstMarker.uiNode )
                                    (useMenuEntryWithTextContainingFirstOf
                                        [ "dock", "jump" ]
                                        menuCascadeCompleted
                                    )
                                    context.readingFromGameClient
                            
                            Nothing ->
                                case context |> knownModulesToActivateAlways |> List.filter (Tuple.second >> .isActive >> Maybe.withDefault False >> not) |> List.head of
                                    Just ( inactiveModuleMatchingText, inactiveModule ) ->
                                        describeBranch ("I see inactive module '" ++ inactiveModuleMatchingText ++ "' to activate always. Activate it.")
                                            (clickModuleButtonButWaitIfClickedInPreviousStep context inactiveModule)

                                    Nothing ->
                                        case inventoryWindowWithOreHoldSelected |> capacityGaugeUsedPercent of
                                            Nothing ->
                                                describeBranch "I do not see the ore hold capacity gauge." askForHelpToGetUnstuck

                                            Just fillPercent ->
                                                let
                                                    describeThresholdToUnload =
                                                        (context.eventContext.appSettings.oreHoldMaxPercent |> String.fromInt) ++ "%"
                                                in
                                                if context.eventContext.appSettings.oreHoldMaxPercent <= fillPercent then
                                                    describeBranch ("The ore hold is filled at least " ++ describeThresholdToUnload ++ ". Unload the ore.")
                                                        (returnDronesToBay context.readingFromGameClient
                                                            |> Maybe.withDefault (dockToUnloadOre context)
                                                        )

                                                else
                                                    describeBranch ("The ore hold is not yet filled " ++ describeThresholdToUnload ++ ". Get more ore from fleet hangar.")
                                                        (case inventoryWindowWithOreHoldSelected |> fleetHangarFromInventoryWindow of
                                                            Nothing ->                             
                                                                describeBranch ("I do not see the fleet hangar under the active ship in the inventory. Approach fleet commander and open fleen hangar.")
                                                                    (case context.readingFromGameClient |> fleetCommanderFromOverviewWindow of
                                                                            Nothing ->
                                                                                case context.readingFromGameClient.fleetBroadcast |> Maybe.andThen (.fleetBroadcast >> List.head) of
                                                                                    Just fleetDestination ->
                                                                                        case fleetDestination.uiNode |> getAllContainedDisplayTexts |> List.head of
                                                                                            Nothing ->
                                                                                                describeBranch ("Cannot find fleet broadcast.") askForHelpToGetUnstuck
                                                                                            Just fleetBroadcastText ->
                                                                                                case (String.split " " fleetBroadcastText |> List.reverse |> List.head) of
                                                                                                        Nothing ->
                                                                                                            describeBranch ("Cannot find fleet broadcast message.") askForHelpToGetUnstuck
                                                                                                        Just actualDestination ->
                                                                                                            case context.readingFromGameClient.infoPanelContainer
                                                                                                                    |> Maybe.andThen .infoPanelLocationInfo
                                                                                                                    |> Maybe.andThen .currentSolarSystemName
                                                                                                            of
                                                                                                                Nothing -> 
                                                                                                                    describeBranch ("Current Solar System Not Found") askForHelpToGetUnstuck
                                                                                                                Just currentSolarSystem ->
                                                                                                                    -- describeBranch ("Actual Destination is: " ++ stringFromBool(actualDestination == currentSolarSystem)) askForHelpToGetUnstuck
                                                                                                                    if (actualDestination == currentSolarSystem) || (actualDestination == "Broadcasts)") then
                                                                                                                        describeBranch ("I see no fleet commander. Warp to fleet commander.")
                                                                                                                            (returnDronesToBay context.readingFromGameClient
                                                                                                                                |> Maybe.withDefault (warpToWatchlistEntry context)
                                                                                                                            )
                                                                                                                    else
                                                                                                                        describeBranch ("Fleet Window found in different solar system. Set destination to fleet commander solar system.")
                                                                                                                            (useContextMenuCascade
                                                                                                                                ( "Fleet destination", fleetDestination )
                                                                                                                                (useMenuEntryWithTextContaining "Set Destination" menuCascadeCompleted)
                                                                                                                                context.readingFromGameClient
                                                                                                                            )

                                                                                    Nothing ->
                                                                                        describeBranch "I see no fleet commander. Warp to fleet commander."      
                                                                                            (returnDronesToBay context.readingFromGameClient
                                                                                                |> Maybe.withDefault (warpToWatchlistEntry context)
                                                                                            )

                                                                            Just fleetCommanderInOverview ->
                                                                                (approachFleetCommanderIfFarEnough context fleetCommanderInOverview
                                                                                    |> Maybe.withDefault
                                                                                        (useContextMenuCascadeOnOverviewEntry
                                                                                            (useMenuEntryWithTextContaining "Open Fleet Hangar" menuCascadeCompleted)
                                                                                            fleetCommanderInOverview
                                                                                            context.readingFromGameClient
                                                                                        )
                                                                                )
                                                                    )

                                                            Just fleetHangar ->
                                                                endDecisionPath
                                                                    (actWithoutFurtherReadings
                                                                        ( "Click the tree entry representing the fleet hangar."
                                                                        , fleetHangar |> clickOnUIElement MouseButtonLeft
                                                                        )
                                                                    )

                                                        )
                                        

inSpaceWithFleetHangarSelected : BotDecisionContext -> SeeUndockingComplete -> EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode
inSpaceWithFleetHangarSelected context seeUndockingComplete inventoryWindowWithFleetHangarSelected =
    if seeUndockingComplete.shipUI |> shipUIIndicatesShipIsWarpingOrJumping then
        describeBranch "I see we are warping."
            ([ returnDronesToBay context.readingFromGameClient
             , readShipUIModuleButtonTooltips context
             ]
                |> List.filterMap identity
                |> List.head
                |> Maybe.withDefault waitForProgressInGame
            )
    else
        case inventoryWindowWithFleetHangarSelected |> capacityGaugeUsedPercent of
            Nothing ->
                describeBranch "I do not see the fleet hangar capacity gauge." askForHelpToGetUnstuck

            Just fillPercent ->
                let
                    describeThresholdToUnload =
                        (1 |> String.fromInt) ++ "%"
                in
                case inventoryWindowWithFleetHangarSelected |> fleetHangarFromInventoryWindow of
                    Nothing ->
                        describeBranch "I do not see the fleet hangar in the inventory." askForHelpToGetUnstuck

                    Just fleetHangar ->
                        (case context.readingFromGameClient |> fleetCommanderFromOverviewWindow of
                            Nothing ->
                                describeBranch "I see no fleet commander. Warp to fleet commander."
                                    (returnDronesToBay context.readingFromGameClient
                                        |> Maybe.withDefault (warpToWatchlistEntry context)
                                    )

                            Just fleetCommanderInOverview ->
                                if 1 <= fillPercent then
                                    describeBranch ("The fleet hangar is filled at least " ++ describeThresholdToUnload ++ ". Move to ore hold.")
                                        (case inventoryWindowWithFleetHangarSelected |> oreHoldFromInventoryWindow of
                                            Nothing ->
                                                describeBranch "I do not see the ore hold in the inventory." askForHelpToGetUnstuck

                                            Just oreHold ->
                                                case inventoryWindowWithFleetHangarSelected |> selectedContainerFirstItemFromInventoryWindow of
                                                    Nothing ->
                                                        describeBranch "I see no item in the fleet hangar. Continue to mine ore."
                                                            (case context.readingFromGameClient.targets |> List.head of
                                                                Nothing ->
                                                                    describeBranch "I see no locked target."
                                                                        (travelToMiningSiteAndLaunchDronesAndTargetAsteroid context)

                                                                Just _ ->
                                                                    {- Depending on the UI configuration, the game client might automatically target rats.
                                                                    To avoid these targets interfering with mining, unlock them here.
                                                                    -}
                                                                    unlockTargetsNotForMining context
                                                                        |> Maybe.withDefault
                                                                            (describeBranch "I see a locked target."
                                                                                (case context |> knownMiningModules |> List.filter (.isActive >> Maybe.withDefault False >> not) |> List.head of
                                                                                    Nothing ->
                                                                                        describeBranch "All known mining modules are active."
                                                                                            (readShipUIModuleButtonTooltips context
                                                                                                |> Maybe.withDefault
                                                                                                    (launchDronesAndSendThemToMine context.readingFromGameClient
                                                                                                        |> Maybe.withDefault waitForProgressInGame
                                                                                                    )
                                                                                            )

                                                                                    Just inactiveModule ->
                                                                                        describeBranch "I see an inactive mining module. Activate it."
                                                                                            (clickModuleButtonButWaitIfClickedInPreviousStep context inactiveModule)
                                                                                )
                                                                            )
                                                            )

                                                    Just itemInInventory ->
                                                        let
                                                            allItemsSelected =
                                                                inventoryWindowWithFleetHangarSelected.uiNode.uiNode
                                                                    |> getAllContainedDisplayTexts
                                                                    |> List.filter (String.toLower >> String.contains "/")
                                                                    |> List.head
                                                        in
                                                        case allItemsSelected of
                                                            Nothing ->
                                                                describeBranch "Select all ore items to drag into ore hold."
                                                                    (useContextMenuCascade
                                                                        ( "Fleet Hangar", itemInInventory )
                                                                            (useMenuEntryWithTextContaining "Select All" menuCascadeCompleted)
                                                                        context.readingFromGameClient
                                                                    )
                                                            Just allItems ->
                                                                describeBranch "I see at least one item in the fleet hangar. Approach fleet commander and move item to the ore hold."
                                                                    (approachFleetCommanderIfFarEnough context fleetCommanderInOverview
                                                                        |> Maybe.withDefault
                                                                            (endDecisionPath
                                                                                (actWithoutFurtherReadings
                                                                                    ( "Drag and drop."
                                                                                    , EffectOnWindow.effectsForFleetDragAndDrop
                                                                                        { startLocation = itemInInventory.totalDisplayRegion |> centerFromDisplayRegion
                                                                                        , endLocation = oreHold.totalDisplayRegion |> centerFromDisplayRegion
                                                                                        , mouseButton = MouseButtonLeft
                                                                                        }
                                                                                    )
                                                                                )
                                                                            )
                                                                    ) 
                                        )

                                else
                                    describeBranch ("The fleet hangar is not yet filled. Wait.")
                                        (approachFleetCommanderIfFarEnough context fleetCommanderInOverview
                                            |> Maybe.withDefault
                                                (endDecisionPath
                                                    (actWithoutFurtherReadings
                                                        ( "Click at scroll control bottom"
                                                        , [ EffectOnWindow.KeyDown EffectOnWindow.vkey_HOME
                                                            , EffectOnWindow.KeyUp EffectOnWindow.vkey_HOME
                                                            ]
                                                        )
                                                    )
                                                )
                                        )


                        )


                        
                        

unlockTargetsNotForMining : BotDecisionContext -> Maybe DecisionPathNode
unlockTargetsNotForMining context =
    let
        targetsToUnlock =
            context.readingFromGameClient.targets
                |> List.filter (.textsTopToBottom >> List.any (String.toLower >> String.contains "asteroid") >> not)
    in
    targetsToUnlock
        |> List.head
        |> Maybe.map
            (\targetToUnlock ->
                describeBranch
                    ("I see a target not for mining: '"
                        ++ (targetToUnlock.textsTopToBottom |> String.join " ")
                        ++ "'. Unlock this target."
                    )
                    (useContextMenuCascade
                        ( "target", targetToUnlock.barAndImageCont |> Maybe.withDefault targetToUnlock.uiNode )
                        (useMenuEntryWithTextContaining "unlock" menuCascadeCompleted)
                        context.readingFromGameClient
                    )
            )


travelToMiningSiteAndLaunchDronesAndTargetAsteroid : BotDecisionContext -> DecisionPathNode
travelToMiningSiteAndLaunchDronesAndTargetAsteroid context =
    case context.readingFromGameClient |> topmostAsteroidFromOverviewWindow of
        Nothing ->
            describeBranch "I see no asteroid in the overview. Warp to mining site."
                (returnDronesToBay context.readingFromGameClient
                    |> Maybe.withDefault
                        (warpToMiningSite context.readingFromGameClient)
                )

        Just asteroidInOverview ->
            describeBranch ("Choosing asteroid '" ++ (asteroidInOverview.objectName |> Maybe.withDefault "Nothing") ++ "'")
                (warpToOverviewEntryIfFarEnough context asteroidInOverview
                    |> Maybe.withDefault
                        (launchDrones context.readingFromGameClient
                            |> Maybe.withDefault
                                (lockTargetFromOverviewEntryAndEnsureIsInRange
                                    context.readingFromGameClient
                                    (min context.eventContext.appSettings.targetingRange
                                        context.eventContext.appSettings.miningModuleRange
                                    )
                                    asteroidInOverview
                                )
                        )
                )


warpToOverviewEntryIfFarEnough : BotDecisionContext -> OverviewWindowEntry -> Maybe DecisionPathNode
warpToOverviewEntryIfFarEnough context destinationOverviewEntry =
    case destinationOverviewEntry.objectDistanceInMeters of
        Ok distanceInMeters ->
            if distanceInMeters <= 150000 then
                Nothing

            else
                Just
                    (describeBranch "Far enough to use Warp"
                        (returnDronesToBay context.readingFromGameClient
                            |> Maybe.withDefault
                                (useContextMenuCascadeOnOverviewEntry
                                    (useMenuEntryWithTextContaining "Warp to Within"
                                        (useMenuEntryWithTextContaining "Within 0 m" menuCascadeCompleted)
                                    )
                                    destinationOverviewEntry
                                    context.readingFromGameClient
                                )
                        )
                    )

        Err error ->
            Just (describeBranch ("Failed to read the distance: " ++ error) askForHelpToGetUnstuck)


approachFleetCommanderIfFarEnough : BotDecisionContext -> OverviewWindowEntry -> Maybe DecisionPathNode
approachFleetCommanderIfFarEnough context fleetCommanderOverviewEntry =
    case fleetCommanderOverviewEntry.objectDistanceInMeters of
        Ok distanceInMeters ->
            if distanceInMeters <= 2500 then
                Nothing

            else
                Just
                    (describeBranch "Far enough to start approaching fleet commander."
                        (useContextMenuCascadeOnOverviewEntry
                            (useMenuEntryWithTextContaining "Orbit" 
                                (useMenuEntryWithTextContaining "500 m" menuCascadeCompleted)
                            )
                            fleetCommanderOverviewEntry
                            context.readingFromGameClient
                        )
                    )

        Err error ->
            Just (describeBranch ("Failed to read the distance: " ++ error) askForHelpToGetUnstuck)

ensureOreHoldIsSelectedInInventoryWindow : BotDecisionContext -> (EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode) -> DecisionPathNode
ensureOreHoldIsSelectedInInventoryWindow context continueWithInventoryWindow =
    case context.readingFromGameClient |> inventoryWindowWithOreHoldSelectedFromGameClient of
        Just inventoryWindow ->
            continueWithInventoryWindow inventoryWindow

        Nothing ->
            case context.readingFromGameClient.inventoryWindows |> List.head of
                Nothing ->
                    -- describeBranch "I do not see an inventory window. Opening inventory window."
                    endDecisionPath
                        (actWithoutFurtherReadings
                            ( "I do not see an inventory window. Opening inventory window."
                            , [ [ EffectOnWindow.KeyDown EffectOnWindow.vkey_I ]
                            , [ EffectOnWindow.KeyUp EffectOnWindow.vkey_I ]
                            ]
                                |> List.concat
                            )
                        )
                Just inventoryWindow ->
                    describeBranch
                        "Ore hold is not selected. Select the ore hold."
                        (case inventoryWindow |> activeShipTreeEntryFromInventoryWindow of
                            Nothing ->
                                describeBranch "I do not see the active ship in the inventory." askForHelpToGetUnstuck

                            Just activeShipTreeEntry ->
                                let
                                    maybeOreHoldTreeEntry =
                                        activeShipTreeEntry.children
                                            |> List.map EveOnline.ParseUserInterface.unwrapInventoryWindowLeftTreeEntryChild
                                            |> List.filter (.text >> String.toLower >> String.contains "ore hold")
                                            |> List.head
                                in
                                case maybeOreHoldTreeEntry of
                                    Nothing ->
                                        describeBranch "I do not see the ore hold under the active ship in the inventory."
                                            (case activeShipTreeEntry.toggleBtn of
                                                Nothing ->
                                                    describeBranch "I do not see the toggle button to expand the active ship tree entry."
                                                        askForHelpToGetUnstuck

                                                Just toggleBtn ->
                                                    endDecisionPath
                                                        (actWithoutFurtherReadings
                                                            ( "Click the toggle button to expand."
                                                            , toggleBtn |> clickOnUIElement MouseButtonLeft
                                                            )
                                                        )
                                            )

                                    Just oreHoldTreeEntry ->
                                        endDecisionPath
                                            (actWithoutFurtherReadings
                                                ( "Click the tree entry representing the ore hold."
                                                , oreHoldTreeEntry.uiNode |> clickOnUIElement MouseButtonLeft
                                                )
                                            )
                        )


ensureItemHangarIsSelectedInInventoryWindow : BotDecisionContext -> (EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode) -> DecisionPathNode
ensureItemHangarIsSelectedInInventoryWindow context continueWithInventoryWindow =
    case context.readingFromGameClient |> inventoryWindowWithItemHangarSelectedFromGameClient of
        Just inventoryWindow ->
            continueWithInventoryWindow inventoryWindow

        Nothing ->
            case context.readingFromGameClient.inventoryWindows |> List.head of
                Nothing ->
                    -- describeBranch "I do not see an inventory window. Opening inventory window."
                    endDecisionPath
                        (actWithoutFurtherReadings
                            ( "I do not see an inventory window. Opening inventory window."
                            , [ [ EffectOnWindow.KeyDown EffectOnWindow.vkey_I ]
                            , [ EffectOnWindow.KeyUp EffectOnWindow.vkey_I ]
                            ]
                                |> List.concat
                            )
                        )
                Just inventoryWindow ->
                    describeBranch
                        "Item hangar is not selected. Select the item hangar."
                        (case inventoryWindow |> activeShipTreeEntryFromInventoryWindow of
                            Nothing ->
                                describeBranch "I do not see the active ship in the inventory." askForHelpToGetUnstuck

                            Just activeShipTreeEntry ->
                                let
                                    maybeItemHangarTreeEntry =
                                        activeShipTreeEntry.children
                                            |> List.map EveOnline.ParseUserInterface.unwrapInventoryWindowLeftTreeEntryChild
                                            |> List.filter (.text >> String.toLower >> String.contains "item hangar")
                                            |> List.head
                                in
                                case maybeItemHangarTreeEntry of
                                    Nothing ->
                                        describeBranch "I do not see the item hangar under the active ship in the inventory."
                                            (case activeShipTreeEntry.toggleBtn of
                                                Nothing ->
                                                    describeBranch "I do not see the toggle button to expand the active ship tree entry."
                                                        askForHelpToGetUnstuck

                                                Just toggleBtn ->
                                                    endDecisionPath
                                                        (actWithoutFurtherReadings
                                                            ( "Click the toggle button to expand."
                                                            , toggleBtn |> clickOnUIElement MouseButtonLeft
                                                            )
                                                        )
                                            )

                                    Just itemHangarTreeEntry ->
                                        endDecisionPath
                                            (actWithoutFurtherReadings
                                                ( "Click the tree entry representing the item hangar."
                                                , itemHangarTreeEntry.uiNode |> clickOnUIElement MouseButtonLeft
                                                )
                                            )
                        )

ensureFleetHangarIsSelectedInInventoryWindow : BotDecisionContext -> (EveOnline.ParseUserInterface.InventoryWindow -> DecisionPathNode) -> DecisionPathNode
ensureFleetHangarIsSelectedInInventoryWindow context continueWithInventoryWindow =
    case context.readingFromGameClient |> inventoryWindowWithFleetHangarSelectedFromGameClient of
        Just inventoryWindow ->
            describeBranch "Fleet hangar found"
                (continueWithInventoryWindow inventoryWindow)

        Nothing ->
            case context.readingFromGameClient.inventoryWindows |> List.head of
                Nothing ->
                    -- describeBranch "I do not see an inventory window. Opening inventory window."
                    endDecisionPath
                        (actWithoutFurtherReadings
                            ( "I do not see an inventory window. Opening inventory window."
                            , [ [ EffectOnWindow.KeyDown EffectOnWindow.vkey_I ]
                            , [ EffectOnWindow.KeyUp EffectOnWindow.vkey_I ]
                            ]
                                |> List.concat
                            )
                        )

                Just inventoryWindow ->
                    case context.readingFromGameClient |> fleetCommanderFromOverviewWindow of
                        Nothing ->
                            describeBranch "I see no fleet commander. Warp to fleet commander."
                                (returnDronesToBay context.readingFromGameClient
                                    |> Maybe.withDefault (warpToWatchlistEntry context)
                                )

                        Just fleetCommanderInOverview ->
                            describeBranch
                                "Fleet hangar is not selected. Select the fleet hangar."
                                (case inventoryWindow |> activeShipTreeEntryFromInventoryWindow of
                                    Nothing ->
                                        describeBranch "I do not see the active ship in the inventory." askForHelpToGetUnstuck

                                    Just activeShipTreeEntry ->
                                        let
                                            maybeFleetHangarTreeEntry =
                                                activeShipTreeEntry.children
                                                    |> List.map EveOnline.ParseUserInterface.unwrapInventoryWindowLeftTreeEntryChild
                                                    |> List.filter (.text >> String.toLower >> String.contains "fleet hangar")
                                                    |> List.head
                                        in
                                        case maybeFleetHangarTreeEntry of
                                            Nothing ->
                                                describeBranch "I do not see the fleet hangar under the active ship in the inventory. Approach fleet commander and open fleen hangar."
                                                    (approachFleetCommanderIfFarEnough context fleetCommanderInOverview
                                                        |> Maybe.withDefault
                                                            (useContextMenuCascadeOnOverviewEntry
                                                                (useMenuEntryWithTextContaining "Open Fleet Hangar" menuCascadeCompleted)
                                                                fleetCommanderInOverview
                                                                context.readingFromGameClient
                                                            )
                                                    )

                                            Just fleetHangarTreeEntry ->  
                                                endDecisionPath
                                                    (actWithoutFurtherReadings
                                                        ( "Click the tree entry representing the fleet hangar."
                                                        , fleetHangarTreeEntry.uiNode |> clickOnUIElement MouseButtonLeft
                                                        )
                                                    )
                                )


lockTargetFromOverviewEntryAndEnsureIsInRange : ReadingFromGameClient -> Int -> OverviewWindowEntry -> DecisionPathNode
lockTargetFromOverviewEntryAndEnsureIsInRange readingFromGameClient rangeInMeters overviewEntry =
    case overviewEntry.objectDistanceInMeters of
        Ok distanceInMeters ->
            if distanceInMeters <= rangeInMeters then
                if overviewEntry.commonIndications.targetedByMe || overviewEntry.commonIndications.targeting then
                    describeBranch "Locking target is in progress, wait for completion." waitForProgressInGame

                else
                    describeBranch "Object is in range. Lock target."
                        (lockTargetFromOverviewEntry overviewEntry readingFromGameClient)

            else
                describeBranch ("Object is not in range (" ++ (distanceInMeters |> String.fromInt) ++ " meters away). Approach.")
                    (if shipManeuverIsApproaching readingFromGameClient then
                        describeBranch "I see we already approach." waitForProgressInGame

                     else
                        useContextMenuCascadeOnOverviewEntry
                            (useMenuEntryWithTextContaining "approach" menuCascadeCompleted)
                            overviewEntry
                            readingFromGameClient
                    )

        Err error ->
            describeBranch ("Failed to read the distance: " ++ error) askForHelpToGetUnstuck


lockTargetFromOverviewEntry : OverviewWindowEntry -> ReadingFromGameClient -> DecisionPathNode
lockTargetFromOverviewEntry overviewEntry readingFromGameClient =
    describeBranch ("Lock target from overview entry '" ++ (overviewEntry.objectName |> Maybe.withDefault "") ++ "'")
        (useContextMenuCascadeOnOverviewEntry
            (useMenuEntryWithTextEqual "Lock target" menuCascadeCompleted)
            overviewEntry
            readingFromGameClient
        )


dockToStationOrStructureWithMatchingName :
    { prioritizeStructures : Bool, nameFromSettingOrInfoPanel : String }
    -> BotDecisionContext
    -> DecisionPathNode
dockToStationOrStructureWithMatchingName { prioritizeStructures, nameFromSettingOrInfoPanel } context =
    let
        displayTextRepresentsMatchingStation =
            simplifyStationOrStructureNameFromSettingsBeforeComparingToMenuEntry
                >> String.startsWith (nameFromSettingOrInfoPanel |> simplifyStationOrStructureNameFromSettingsBeforeComparingToMenuEntry)

        matchingOverviewEntry =
            context.readingFromGameClient.overviewWindow
                |> Maybe.map .entries
                |> Maybe.withDefault []
                |> List.filter (.objectName >> Maybe.map displayTextRepresentsMatchingStation >> Maybe.withDefault False)
                |> List.head

        overviewWindowScrollControls =
            context.readingFromGameClient.overviewWindow
                |> Maybe.andThen .scrollControls
    in
    matchingOverviewEntry
        |> Maybe.map
            (\entry ->
                EveOnline.AppFramework.useContextMenuCascadeOnOverviewEntry
                    (useMenuEntryWithTextContaining "dock" menuCascadeCompleted)
                    entry
                    context.readingFromGameClient
            )
        |> Maybe.withDefault
                (returnDronesToBay context.readingFromGameClient
                    |> Maybe.withDefault
                        (warpToRefineryStructure context)
                )
            -- (overviewWindowScrollControls
            --     |> Maybe.andThen scrollDown
            --     |> Maybe.withDefault
            --         (describeBranch "I do not see the station in the overview window. I use the menu from the surroundings button."
            --             (dockToStationOrStructureUsingSurroundingsButtonMenu
            --                 { prioritizeStructures = prioritizeStructures
            --                 , describeChoice = "representing the station or structure '" ++ nameFromSettingOrInfoPanel ++ "'."
            --                 , chooseEntry =
            --                     List.filter (.text >> displayTextRepresentsMatchingStation) >> List.head
            --                 }
            --                 readingFromGameClient
            --             )
            --         )
            -- )


scrollDown : EveOnline.ParseUserInterface.ScrollControls -> Maybe DecisionPathNode
scrollDown scrollControls =
    case scrollControls.scrollHandle of
        Nothing ->
            Nothing

        Just scrollHandle ->
            let
                scrollControlsTotalDisplayRegion =
                    scrollControls.uiNode.totalDisplayRegion

                scrollControlsBottom =
                    scrollControlsTotalDisplayRegion.y + scrollControlsTotalDisplayRegion.height

                freeHeightAtBottom =
                    scrollControlsBottom
                        - (scrollHandle.totalDisplayRegion.y + scrollHandle.totalDisplayRegion.height)
            in
            if 10 < freeHeightAtBottom then
                Just
                    (endDecisionPath
                        (actWithoutFurtherReadings
                            ( "Click at scroll control bottom"
                            , EffectOnWindow.effectsMouseClickAtLocation EffectOnWindow.MouseButtonLeft
                                { x = scrollControlsTotalDisplayRegion.x + 3
                                , y = scrollControlsBottom - 8
                                }
                                ++ [ EffectOnWindow.KeyDown EffectOnWindow.vkey_END
                                   , EffectOnWindow.KeyUp EffectOnWindow.vkey_END
                                   ]
                            )
                        )
                    )

            else
                Nothing


{-| Prepare a station name or structure name coming from app-settings for comparing with menu entries.
  - The user could take the name from the info panel:
    The names sometimes differ between info panel and menu entries: 'Moon 7' can become 'M7'.
  - Do not distinguish between the comma and period characters:
    Besides the similar visual appearance, also because of the limitations of popular app-settings parsing frameworks.
    The user can remove a comma or replace it with a full stop/period, whatever looks better.
-}
simplifyStationOrStructureNameFromSettingsBeforeComparingToMenuEntry : String -> String
simplifyStationOrStructureNameFromSettingsBeforeComparingToMenuEntry =
    String.toLower >> String.replace "moon " "m" >> String.replace "," "" >> String.replace "." "" >> String.trim


dockToStationOrStructureUsingSurroundingsButtonMenu :
    { prioritizeStructures : Bool
    , describeChoice : String
    , chooseEntry : List EveOnline.ParseUserInterface.ContextMenuEntry -> Maybe EveOnline.ParseUserInterface.ContextMenuEntry
    }
    -> ReadingFromGameClient
    -> DecisionPathNode
dockToStationOrStructureUsingSurroundingsButtonMenu { prioritizeStructures, describeChoice, chooseEntry } =
    useContextMenuCascadeOnListSurroundingsButton
        (useMenuEntryWithTextContainingFirstOf
            ([ "stations", "structures" ]
                |> (if prioritizeStructures then
                        List.reverse

                    else
                        identity
                   )
            )
            (useMenuEntryInLastContextMenuInCascade { describeChoice = describeChoice, chooseEntry = chooseEntry }
                (useMenuEntryWithTextContaining "dock" menuCascadeCompleted)
            )
        )

warpToWatchlistEntry : BotDecisionContext -> DecisionPathNode
warpToWatchlistEntry context =
    case context.readingFromGameClient.watchListPanel |> Maybe.andThen (.entries >> List.head) of
        Just watchlistEntry ->
            describeBranch "Warp to entry in watchlist panel."
                (useContextMenuCascade
                    ( "Watchlist entry", watchlistEntry )
                    (useMenuEntryWithTextContainingFirstOf
                        [ "approach", "warp to member within" ]
                        (useMenuEntryWithTextContaining "Within 0 m" menuCascadeCompleted)
                    )
                    -- (useMenuEntryWithTextContaining "Warp to Member Within"
                    --     (useMenuEntryWithTextContaining "Within 0 m" menuCascadeCompleted)
                    -- )
                    context.readingFromGameClient
                )

        Nothing ->
            describeBranch "I see no entry in the watchlist panel. Warping directly to mining site."
                (warpToMiningSite context.readingFromGameClient)

warpToRefineryStructure : BotDecisionContext -> DecisionPathNode
warpToRefineryStructure context =
    case context.readingFromGameClient.groupWindow |> Maybe.andThen (.entries >> List.head) of
        Just groupEntry ->
            describeBranch "Warp to refinery structure in group window."
                (useContextMenuCascade
                    ( "Group entry", groupEntry )
                    (useMenuEntryWithTextContainingFirstOf
                        [ "dock", "jump" ]
                        menuCascadeCompleted
                    )
                    context.readingFromGameClient
                )

        Nothing ->
            describeBranch "I see no entry in the group window. Warping directly to mining site."
                (warpToMiningSite context.readingFromGameClient)

approachWatchlistEntry : BotDecisionContext -> DecisionPathNode
approachWatchlistEntry context =
    case context.readingFromGameClient.watchListPanel |> Maybe.andThen (.entries >> List.head) of
        Just watchlistEntry ->
            describeBranch "Approach entry in watchlist panel."
                (useContextMenuCascade
                    ( "Watchlist entry", watchlistEntry )
                    (useMenuEntryWithTextContaining "Approach" menuCascadeCompleted)
                    context.readingFromGameClient
                )

        Nothing ->
            describeBranch "I see no entry in the watchlist panel. Warping directly to mining site."
                (warpToMiningSite context.readingFromGameClient)

warpToMiningSite : ReadingFromGameClient -> DecisionPathNode
warpToMiningSite readingFromGameClient =
    readingFromGameClient
        |> useContextMenuCascadeOnListSurroundingsButton
            (useMenuEntryWithTextContaining "location"
                (useRandomMenuEntry
                    (useMenuEntryWithTextContaining "Warp to Location Within 0 m" menuCascadeCompleted)
                )
            )


runAway : BotDecisionContext -> DecisionPathNode
runAway context =
    dockToRandomStationOrStructure context.readingFromGameClient


dockToUnloadOre : BotDecisionContext -> DecisionPathNode
dockToUnloadOre context =
    case context.eventContext.appSettings.unloadStationName of
        Just unloadStationName ->
            dockToStationOrStructureWithMatchingName
                { prioritizeStructures = False, nameFromSettingOrInfoPanel = unloadStationName }
                context

        Nothing ->
            case context.eventContext.appSettings.unloadStructureName of
                Just unloadStructureName ->
                    dockToStationOrStructureWithMatchingName
                        { prioritizeStructures = True, nameFromSettingOrInfoPanel = unloadStructureName }
                        context

                Nothing ->
                    describeBranch "At which station should I dock?. I was never docked in a station in this session." askForHelpToGetUnstuck


dockToRandomStationOrStructure : ReadingFromGameClient -> DecisionPathNode
dockToRandomStationOrStructure readingFromGameClient =
    dockToStationOrStructureUsingSurroundingsButtonMenu
        { prioritizeStructures = False
        , describeChoice = "Pick random station"
        , chooseEntry = listElementAtWrappedIndex (getEntropyIntFromReadingFromGameClient readingFromGameClient)
        }
        readingFromGameClient


launchDrones : ReadingFromGameClient -> Maybe DecisionPathNode
launchDrones readingFromGameClient =
    readingFromGameClient.dronesWindow
        |> Maybe.andThen
            (\dronesWindow ->
                case ( dronesWindow.droneGroupInBay, dronesWindow.droneGroupInLocalSpace ) of
                    ( Just droneGroupInBay, Just droneGroupInLocalSpace ) ->
                        let
                            dronesInBayQuantity =
                                droneGroupInBay.header.quantityFromTitle |> Maybe.withDefault 0

                            dronesInLocalSpaceQuantity =
                                droneGroupInLocalSpace.header.quantityFromTitle |> Maybe.withDefault 0
                        in
                        if 0 < dronesInBayQuantity && dronesInLocalSpaceQuantity < 5 then
                            Just
                                (describeBranch "Launch drones"
                                    (useContextMenuCascade
                                        ( "drones group", droneGroupInBay.header.uiNode )
                                        (useMenuEntryWithTextContaining "Launch drones" menuCascadeCompleted)
                                        readingFromGameClient
                                    )
                                )

                        else
                            Nothing

                    _ ->
                        Nothing
            )


launchDronesAndSendThemToMine : ReadingFromGameClient -> Maybe DecisionPathNode
launchDronesAndSendThemToMine readingFromGameClient =
    readingFromGameClient.dronesWindow
        |> Maybe.andThen
            (\dronesWindow ->
                case ( dronesWindow.droneGroupInBay, dronesWindow.droneGroupInLocalSpace ) of
                    ( Just droneGroupInBay, Just droneGroupInLocalSpace ) ->
                        let
                            idlingDrones =
                                droneGroupInLocalSpace.drones
                                    |> List.filter (.uiNode >> .uiNode >> EveOnline.ParseUserInterface.getAllContainedDisplayTexts >> List.any (String.toLower >> String.contains "idle"))

                            dronesInBayQuantity =
                                droneGroupInBay.header.quantityFromTitle |> Maybe.withDefault 0

                            dronesInLocalSpaceQuantity =
                                droneGroupInLocalSpace.header.quantityFromTitle |> Maybe.withDefault 0
                        in
                        if 0 < (idlingDrones |> List.length) then
                            Just
                                (describeBranch "Send idling drone(s)"
                                    (useContextMenuCascade
                                        ( "drones group", droneGroupInLocalSpace.header.uiNode )
                                        (useMenuEntryWithTextContaining "mine" menuCascadeCompleted)
                                        readingFromGameClient
                                    )
                                )

                        else if 0 < dronesInBayQuantity && dronesInLocalSpaceQuantity < 5 then
                            Just
                                (describeBranch "Launch drones"
                                    (useContextMenuCascade
                                        ( "drones group", droneGroupInBay.header.uiNode )
                                        (useMenuEntryWithTextContaining "Launch drones" menuCascadeCompleted)
                                        readingFromGameClient
                                    )
                                )

                        else
                            Nothing

                    _ ->
                        Nothing
            )


returnDronesToBay : ReadingFromGameClient -> Maybe DecisionPathNode
returnDronesToBay readingFromGameClient =
    readingFromGameClient.dronesWindow
        |> Maybe.andThen .droneGroupInLocalSpace
        |> Maybe.andThen
            (\droneGroupInLocalSpace ->
                if (droneGroupInLocalSpace.header.quantityFromTitle |> Maybe.withDefault 0) < 1 then
                    Nothing

                else
                    Just
                        (describeBranch "I see there are drones in local space. Return those to bay."
                            (useContextMenuCascade
                                ( "drones group", droneGroupInLocalSpace.header.uiNode )
                                (useMenuEntryWithTextContaining "Return to drone bay" menuCascadeCompleted)
                                readingFromGameClient
                            )
                        )
            )


readShipUIModuleButtonTooltips : BotDecisionContext -> Maybe DecisionPathNode
readShipUIModuleButtonTooltips =
    EveOnline.AppFramework.readShipUIModuleButtonTooltipWhereNotYetInMemory


knownMiningModules : BotDecisionContext -> List EveOnline.ParseUserInterface.ShipUIModuleButton
knownMiningModules context =
    context.readingFromGameClient.shipUI
        |> Maybe.map .moduleButtons
        |> Maybe.withDefault []
        |> List.filter
            (EveOnline.AppFramework.getModuleButtonTooltipFromModuleButton context.memory.shipModules
                >> Maybe.map tooltipLooksLikeMiningModule
                >> Maybe.withDefault False
            )


knownModulesToActivateAlways : BotDecisionContext -> List ( String, EveOnline.ParseUserInterface.ShipUIModuleButton )
knownModulesToActivateAlways context =
    context.readingFromGameClient.shipUI
        |> Maybe.map .moduleButtons
        |> Maybe.withDefault []
        |> List.filterMap
            (\moduleButton ->
                moduleButton
                    |> EveOnline.AppFramework.getModuleButtonTooltipFromModuleButton context.memory.shipModules
                    |> Maybe.andThen (tooltipLooksLikeModuleToActivateAlways context)
                    |> Maybe.map (\moduleName -> ( moduleName, moduleButton ))
            )


tooltipLooksLikeMiningModule : EveOnline.ParseUserInterface.ModuleButtonTooltip -> Bool
tooltipLooksLikeMiningModule =
    .uiNode
        >> .uiNode
        >> getAllContainedDisplayTexts
        >> List.any
            (Regex.fromString "\\d\\s*m3\\s*\\/\\s*s" |> Maybe.map Regex.contains |> Maybe.withDefault (always False))


tooltipLooksLikeModuleToActivateAlways : BotDecisionContext -> EveOnline.ParseUserInterface.ModuleButtonTooltip -> Maybe String
tooltipLooksLikeModuleToActivateAlways context =
    .uiNode
        >> .uiNode
        >> getAllContainedDisplayTexts
        >> List.filterMap
            (\tooltipText ->
                context.eventContext.appSettings.modulesToActivateAlways
                    |> List.filterMap
                        (\moduleToActivateAlways ->
                            if tooltipText |> String.toLower |> String.contains (moduleToActivateAlways |> String.toLower) then
                                Just tooltipText

                            else
                                Nothing
                        )
                    |> List.head
            )
        >> List.head


initState : State
initState =
    EveOnline.AppFramework.initState
        (EveOnline.AppFramework.initStateWithMemoryAndDecisionTree
            { lastDockedStationNameFromInfoPanel = Nothing
            , timesUnloaded = 0
            , volumeUnloadedCubicMeters = 0
            , lastUsedCapacityInOreHold = Nothing
            , shipModules = EveOnline.AppFramework.initShipModulesMemory
            }
        )


processEvent : InterfaceToHost.AppEvent -> State -> ( State, InterfaceToHost.AppResponse )
processEvent =
    EveOnline.AppFramework.processEvent
        { parseAppSettings = parseBotSettings
        , selectGameClientInstance =
            Maybe.andThen .selectInstancePilotName
                >> Maybe.map EveOnline.AppFramework.selectGameClientInstanceWithPilotName
                >> Maybe.withDefault EveOnline.AppFramework.selectGameClientInstanceWithTopmostWindow
        , processEvent = processEveOnlineBotEvent
        }


processEveOnlineBotEvent :
    EveOnline.AppFramework.AppEventContext BotSettings
    -> EveOnline.AppFramework.AppEvent
    -> BotState
    -> ( BotState, EveOnline.AppFramework.AppEventResponse )
processEveOnlineBotEvent =
    EveOnline.AppFramework.processEveOnlineAppEventWithMemoryAndDecisionTree
        { updateMemoryForNewReadingFromGame = updateMemoryForNewReadingFromGame
        , statusTextFromState = statusTextFromState
        , decisionTreeRoot = miningBotDecisionRoot
        , millisecondsToNextReadingFromGame = .eventContext >> .appSettings >> .botStepDelayMilliseconds
        }


statusTextFromState : BotDecisionContext -> String
statusTextFromState context =
    let
        readingFromGameClient =
            context.readingFromGameClient

        describeSessionPerformance =
            [ ( "times unloaded", context.memory.timesUnloaded )
            , ( "volume unloaded / m©ø", context.memory.volumeUnloadedCubicMeters )
            ]
                |> List.map (\( metric, amount ) -> metric ++ ": " ++ (amount |> String.fromInt))
                |> String.join ", "

        describeShip =
            case readingFromGameClient.shipUI of
                Just shipUI ->
                    [ "Shield HP at " ++ (shipUI.hitpointsPercent.shield |> String.fromInt) ++ "%."
                    , "Found " ++ (context |> knownMiningModules |> List.length |> String.fromInt) ++ " mining modules."
                    ]
                        |> String.join " "

                Nothing ->
                    case
                        readingFromGameClient.infoPanelContainer
                            |> Maybe.andThen .infoPanelLocationInfo
                            |> Maybe.andThen .expandedContent
                            |> Maybe.andThen .currentStationName
                    of
                        Just stationName ->
                            "I am docked at '" ++ stationName ++ "'."

                        Nothing ->
                            "I do not see if I am docked or in space. Please set up game client first."

        describeDrones =
            case readingFromGameClient.dronesWindow of
                Nothing ->
                    "I do not see the drones window."

                Just dronesWindow ->
                    "I see the drones window: In bay: "
                        ++ (dronesWindow.droneGroupInBay |> Maybe.andThen (.header >> .quantityFromTitle) |> Maybe.map String.fromInt |> Maybe.withDefault "Unknown")
                        ++ ", in local space: "
                        ++ (dronesWindow.droneGroupInLocalSpace |> Maybe.andThen (.header >> .quantityFromTitle) |> Maybe.map String.fromInt |> Maybe.withDefault "Unknown")
                        ++ "."

        describeOreHold =
            "Ore hold filled "
                ++ (readingFromGameClient
                        |> inventoryWindowWithOreHoldSelectedFromGameClient
                        |> Maybe.andThen capacityGaugeUsedPercent
                        |> Maybe.map String.fromInt
                        |> Maybe.withDefault "Unknown"
                   )
                ++ "%."

        describeCurrentReading =
            [ describeOreHold, describeShip, describeDrones ] |> String.join " "
    in
    [ "Session performance: " ++ describeSessionPerformance
    , "---"
    , "Current reading: " ++ describeCurrentReading
    ]
        |> String.join "\n"


updateMemoryForNewReadingFromGame : ReadingFromGameClient -> BotMemory -> BotMemory
updateMemoryForNewReadingFromGame currentReading botMemoryBefore =
    let
        currentStationNameFromInfoPanel =
            currentReading.infoPanelContainer
                |> Maybe.andThen .infoPanelLocationInfo
                |> Maybe.andThen .expandedContent
                |> Maybe.andThen .currentStationName

        lastUsedCapacityInOreHold =
            currentReading
                |> inventoryWindowWithOreHoldSelectedFromGameClient
                |> Maybe.andThen .selectedContainerCapacityGauge
                |> Maybe.andThen Result.toMaybe
                |> Maybe.map .used

        completedUnloadSincePreviousReading =
            case botMemoryBefore.lastUsedCapacityInOreHold of
                Nothing ->
                    False

                Just previousUsedCapacityInOreHold ->
                    lastUsedCapacityInOreHold == Just 0 && 0 < previousUsedCapacityInOreHold

        volumeUnloadedSincePreviousReading =
            case botMemoryBefore.lastUsedCapacityInOreHold of
                Nothing ->
                    0

                Just previousUsedCapacityInOreHold ->
                    case lastUsedCapacityInOreHold of
                        Nothing ->
                            0

                        Just currentUsedCapacityInOreHold ->
                            -- During mining, when new ore appears in the inventory, this difference is negative.
                            max 0 (previousUsedCapacityInOreHold - currentUsedCapacityInOreHold)

        timesUnloaded =
            botMemoryBefore.timesUnloaded
                + (if completedUnloadSincePreviousReading then
                    1

                   else
                    0
                  )

        volumeUnloadedCubicMeters =
            botMemoryBefore.volumeUnloadedCubicMeters + volumeUnloadedSincePreviousReading
    in
    { lastDockedStationNameFromInfoPanel =
        [ currentStationNameFromInfoPanel, botMemoryBefore.lastDockedStationNameFromInfoPanel ]
            |> List.filterMap identity
            |> List.head
    , timesUnloaded = timesUnloaded
    , volumeUnloadedCubicMeters = volumeUnloadedCubicMeters
    , lastUsedCapacityInOreHold = lastUsedCapacityInOreHold
    , shipModules =
        botMemoryBefore.shipModules
            |> EveOnline.AppFramework.integrateCurrentReadingsIntoShipModulesMemory currentReading
    }


clickModuleButtonButWaitIfClickedInPreviousStep : BotDecisionContext -> EveOnline.ParseUserInterface.ShipUIModuleButton -> DecisionPathNode
clickModuleButtonButWaitIfClickedInPreviousStep context moduleButton =
    if doEffectsClickModuleButton moduleButton context.previousStepEffects then
        describeBranch "Already clicked on this module button in previous step." waitForProgressInGame

    else
        endDecisionPath
            (actWithoutFurtherReadings
                ( "Click on this module button."
                , moduleButton.uiNode |> clickOnUIElement MouseButtonLeft
                )
            )


activeShipTreeEntryFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe EveOnline.ParseUserInterface.InventoryWindowLeftTreeEntry
activeShipTreeEntryFromInventoryWindow =
    .leftTreeEntries
        -- Assume upmost entry is active ship.
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


topmostAsteroidFromOverviewWindow : ReadingFromGameClient -> Maybe OverviewWindowEntry
topmostAsteroidFromOverviewWindow =
    overviewWindowEntriesRepresentingAsteroids
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


overviewWindowEntriesRepresentingAsteroids : ReadingFromGameClient -> List OverviewWindowEntry
overviewWindowEntriesRepresentingAsteroids =
    .overviewWindow
        >> Maybe.map (.entries >> List.filter overviewWindowEntryRepresentsAnAsteroid)
        >> Maybe.withDefault []


overviewWindowEntryRepresentsAnAsteroid : OverviewWindowEntry -> Bool
overviewWindowEntryRepresentsAnAsteroid entry =
    (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "asteroid"))
        && (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "belt") |> not)

fleetCommanderFromOverviewWindow : ReadingFromGameClient -> Maybe OverviewWindowEntry
fleetCommanderFromOverviewWindow =
    overviewWindowEntriesRepresentingFleetCommander
        >> List.filter overviewWindowEntryRepresentsFleetCommander
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


overviewWindowEntriesRepresentingFleetCommander : ReadingFromGameClient -> List OverviewWindowEntry
overviewWindowEntriesRepresentingFleetCommander =
    .overviewWindow
        >> Maybe.map (.entries >> List.filter overviewWindowEntryRepresentsFleetCommander)
        >> Maybe.withDefault []


overviewWindowEntryRepresentsFleetCommander : OverviewWindowEntry -> Bool
overviewWindowEntryRepresentsFleetCommander entry =
    (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "tris"))

capacityGaugeUsedPercent : EveOnline.ParseUserInterface.InventoryWindow -> Maybe Int
capacityGaugeUsedPercent =
    .selectedContainerCapacityGauge
        >> Maybe.andThen Result.toMaybe
        >> Maybe.andThen
            (\capacity -> capacity.maximum |> Maybe.map (\maximum -> capacity.used * 100 // maximum))


inventoryWindowWithOreHoldSelectedFromGameClient : ReadingFromGameClient -> Maybe EveOnline.ParseUserInterface.InventoryWindow
inventoryWindowWithOreHoldSelectedFromGameClient =
    .inventoryWindows
        >> List.filter inventoryWindowSelectedContainerIsOreHold
        >> List.head

inventoryWindowWithItemHangarSelectedFromGameClient : ReadingFromGameClient -> Maybe EveOnline.ParseUserInterface.InventoryWindow
inventoryWindowWithItemHangarSelectedFromGameClient =
    .inventoryWindows
        >> List.filter inventoryWindowSelectedContainerIsItemHangar
        >> List.head

inventoryWindowWithFleetHangarSelectedFromGameClient : ReadingFromGameClient -> Maybe EveOnline.ParseUserInterface.InventoryWindow
inventoryWindowWithFleetHangarSelectedFromGameClient =
    .inventoryWindows
        >> List.filter inventoryWindowSelectedContainerIsFleetHangar
        >> List.head

inventoryWindowSelectedContainerIsOreHold : EveOnline.ParseUserInterface.InventoryWindow -> Bool
inventoryWindowSelectedContainerIsOreHold =
    .subCaptionLabelText >> Maybe.map (String.toLower >> String.contains "ore hold") >> Maybe.withDefault False

inventoryWindowSelectedContainerIsItemHangar : EveOnline.ParseUserInterface.InventoryWindow -> Bool
inventoryWindowSelectedContainerIsItemHangar =
    .subCaptionLabelText >> Maybe.map (String.toLower >> String.contains "item hangar") >> Maybe.withDefault False

inventoryWindowSelectedContainerIsFleetHangar : EveOnline.ParseUserInterface.InventoryWindow -> Bool
inventoryWindowSelectedContainerIsFleetHangar =
    .subCaptionLabelText >> Maybe.map (String.toLower >> String.contains "fleet hangar") >> Maybe.withDefault False

selectedContainerFirstItemFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe UIElement
selectedContainerFirstItemFromInventoryWindow =
    .selectedContainerInventory
        >> Maybe.andThen .itemsView
        >> Maybe.map
            (\itemsView ->
                case itemsView of
                    EveOnline.ParseUserInterface.InventoryItemsListView { items } ->
                        items

                    EveOnline.ParseUserInterface.InventoryItemsNotListView { items } ->
                        items
            )
        >> Maybe.andThen List.head

selectedContainerAllItemsFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe (List EveOnline.ParseUserInterface.UITreeNodeWithDisplayRegion)
selectedContainerAllItemsFromInventoryWindow =
    .selectedContainerInventory
        >> Maybe.andThen .itemsView
        >> Maybe.map
            (\itemsView ->
                case itemsView of
                    EveOnline.ParseUserInterface.InventoryItemsListView { items } ->
                        items

                    EveOnline.ParseUserInterface.InventoryItemsNotListView { items } ->
                        items
            )

itemHangarFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe UIElement
itemHangarFromInventoryWindow =
    .leftTreeEntries
        >> List.filter (.text >> String.toLower >> String.contains "item hangar")
        >> List.head
        >> Maybe.map .uiNode

oreHoldFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe UIElement
oreHoldFromInventoryWindow =
    .leftTreeEntries
        >> List.concatMap (.children >> List.map EveOnline.ParseUserInterface.unwrapInventoryWindowLeftTreeEntryChild)
        >> List.filter (.text >> String.toLower >> String.contains "ore hold")
        >> List.head
        >> Maybe.map .uiNode

fleetHangarFromInventoryWindow : EveOnline.ParseUserInterface.InventoryWindow -> Maybe UIElement
fleetHangarFromInventoryWindow =
    .leftTreeEntries
        >> List.filter (.text >> String.toLower >> String.contains "fleet hangar")
        >> List.head
        >> Maybe.map .uiNode

{-| The region of a ship entry in the inventory window can contain child nodes (e.g. 'Ore Hold').
For this reason, we don't click on the center but stay close to the top.
-}
predictUIElementInventoryShipEntry : EveOnline.ParseUserInterface.InventoryWindowLeftTreeEntry -> UIElement
predictUIElementInventoryShipEntry treeEntry =
    let
        originalUIElement =
            treeEntry.uiNode

        originalTotalDisplayRegion =
            originalUIElement.totalDisplayRegion

        totalDisplayRegion =
            { originalTotalDisplayRegion | height = 10 }
    in
    { originalUIElement | totalDisplayRegion = totalDisplayRegion }


shipManeuverIsApproaching : ReadingFromGameClient -> Bool
shipManeuverIsApproaching =
    .shipUI
        >> Maybe.andThen .indication
        >> Maybe.andThen .maneuverType
        >> Maybe.map ((==) EveOnline.ParseUserInterface.ManeuverApproach)
        -- If the ship is just floating in space, there might be no indication displayed.
        >> Maybe.withDefault False


stringFromBool : Bool -> String
stringFromBool value =
  if value then
    "True"

  else
    "False"