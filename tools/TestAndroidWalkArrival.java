package io.github.echolupus802612.lukangwalk;

public final class TestAndroidWalkArrival {
    private static void expect(boolean wanted, boolean result) {
        if (result != wanted) throw new AssertionError("到站判定和預期不符");
    }
    public static void main(String[] args) {
        WalkArrivalCheck check = new WalkArrivalCheck();
        expect(false,check.confirms(27,4,1000,1000,900,0));
        expect(false,check.confirms(27,4,1000,1100,900,0));
        expect(true,check.confirms(27,4,2000,2000,900,0));
        expect(false,check.confirms(28,4,3000,3000,900,0));
        expect(false,check.confirms(27,4,4000,4000,900,0));
        expect(false,check.confirms(24,4,5000,5000,4500,25));
        expect(false,check.confirms(24,41,6000,6000,4500,25));
        expect(false,check.confirms(24,4,7000,7000,4500,25));
        expect(false,check.confirms(24,4,38000,38000,4500,25));
        expect(false,check.confirms(90,4,39000,39000,38500,100));
        expect(true,check.confirms(95,4,40000,40000,38500,100));
        expect(false,check.confirms(25,5,42000,72001,41500,50));
        expect(false,check.confirms(25,5,43000,42999,41500,50));
        System.out.println("Android 到站半徑、時間與連續定位測試通過。");
    }
}
