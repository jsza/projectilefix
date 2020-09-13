#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <dhooks>
#include <sdktools>


Handle g_hSetPlayerSimulated;


public Plugin myinfo =
{
    name = "projectilefix",
    author = "jayess",
    description = "fixes/improvements for rockets and stickybombs in tf2",
    version = "0.0",
    url = "https://github.com/jsza/projectilefix"
}


public void OnPluginStart() {
    GameData data = LoadGameConfigFile("projectilefix.games");
    if (!data)
        SetFailState("Missing gamedata!");

    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(data, SDKConf_Signature, "SetPlayerSimulated");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    g_hSetPlayerSimulated = EndPrepSDKCall();
}


public ProjectileSpawned(entity) {
    decl String:targetname[128];
    GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
    if (StrEqual(targetname, "dontcopy")) {
        return;
    }
    int owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
    if (1 <= owner <= MaxClients)
        SDKCall(g_hSetPlayerSimulated, entity, owner);

    //float origin[3];
    //float angles[3];
    //float velocity[3];

    //GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    //GetEntDataVector(entity, FindSendPropInfo("CTFProjectile_Rocket", "m_angRotation"), angles);
    //GetEntDataVector(entity, FindSendPropInfo("CTFProjectile_Rocket", "m_vecVelocity"), velocity);
    //origin[2] += 0.5;

    //int ghost = CreateEntityByName("tf_projectile_rocket");
    //DispatchKeyValue(ghost, "targetname", "dontcopy");
    //TeleportEntity(ghost, origin, angles, velocity);
    //SetEntDataEnt2(ghost, FindSendPropInfo("CTFProjectile_Rocket", "m_hOwnerEntity"), owner, true);
    //SetEntData(ghost, FindSendPropInfo("CTFProjectile_Rocket", "m_iTeamNum"), GetClientTeam(owner), true);
    //SetEntData(ghost, FindSendPropInfo("CTFProjectile_Rocket", "m_bCritical"), 1, 1, true);
    ////SetEntDataVector(ghost, FindSendPropInfo("CTFProjectile_Rocket", "m_angRotation"), angles, true);

    //DispatchSpawn(ghost);
}


public void OnEntityCreated(int entity, const char[] classname) {
    if (strcmp(classname, "tf_projectile_rocket") == 0)
        SDKHook(entity, SDKHook_Spawn, ProjectileSpawned);
}
